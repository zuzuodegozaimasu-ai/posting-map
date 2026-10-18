-- =============================================================
-- 配布マップ：料金プラン（無料／個人／チーム）の追加
-- 今あるデータは消えません。SQL Editor に貼り付けて「Run」（1回だけ）
-- =============================================================

-- ---------- 契約（Stripeから自動で書き込まれる） ----------
create table if not exists public.subscriptions (
  id                 text primary key,             -- Stripe の subscription id
  user_id            uuid not null references auth.users on delete cascade,  -- 支払う人
  plan               text not null check (plan in ('personal','team')),
  group_id           uuid references public.groups on delete set null,       -- チームプランの対象グループ
  status             text not null,                -- active / trialing / past_due / canceled など
  current_period_end timestamptz,
  stripe_customer_id text,
  updated_at         timestamptz not null default now()
);
create index if not exists subscriptions_user_idx on public.subscriptions (user_id);
create index if not exists subscriptions_group_idx on public.subscriptions (group_id);

-- Stripe の顧客ID（決済画面を開くたびに同じ顧客として扱うため）
create table if not exists public.billing_customers (
  user_id            uuid primary key references auth.users on delete cascade,
  stripe_customer_id text not null unique
);

alter table public.subscriptions enable row level security;
alter table public.billing_customers enable row level security;
-- 自分の契約だけ読める。書き込みはサーバー（Stripe連携）だけ
drop policy if exists "own subscriptions" on public.subscriptions;
create policy "own subscriptions" on public.subscriptions for select to authenticated using (user_id = auth.uid());
grant select on public.subscriptions to authenticated;
revoke insert, update, delete on public.subscriptions from authenticated, anon;
revoke all on public.billing_customers from authenticated, anon;

-- ---------- 判定用の関数 ----------
create or replace function public.is_pro(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.subscriptions
    where user_id = uid and plan = 'personal' and status in ('active','trialing')
      and (current_period_end is null or current_period_end > now() - interval '1 day'));
$$;

create or replace function public.is_team(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.subscriptions
    where group_id = gid and plan = 'team' and status in ('active','trialing')
      and (current_period_end is null or current_period_end > now() - interval '1 day'));
$$;

-- このグループで有料機能が使えるか（個人プラン、またはグループがチームプラン）
create or replace function public.has_paid(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_pro(auth.uid()) or public.is_team(gid);
$$;

-- 無料枠として数えるグループ数（チームプランのグループは数えない）
create or replace function public.free_group_count() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.members m
  where m.user_id = auth.uid() and not public.is_team(m.group_id);
$$;

-- アプリ表示用：自分のプラン情報
create or replace function public.my_plan(gid uuid default null) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'pro', public.is_pro(auth.uid()),
    'team', case when gid is null then false else public.is_team(gid) end,
    'free_groups', public.free_group_count()
  );
$$;

grant execute on function public.is_pro(uuid), public.is_team(uuid), public.has_paid(uuid),
  public.free_group_count(), public.my_plan(uuid) to authenticated;

-- ---------- グループ数の制限 ----------
create or replace function public.create_group(p_name text) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  if not public.is_pro(auth.uid()) and public.free_group_count() >= 1 then
    raise exception 'free_limit:無料プランで参加できるグループは1つまでです。個人プランにすると、いくつでも作成・参加できます。';
  end if;
  insert into public.groups (name, created_by) values (trim(p_name), auth.uid()) returning * into g;
  insert into public.members (group_id, user_id, role) values (g.id, auth.uid(), 'owner');
  return g;
end $$;

create or replace function public.join_group(p_code text) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into g from public.groups where invite_code = lower(trim(p_code));
  if g.id is null then raise exception '招待コードが見つかりません'; end if;
  if exists (select 1 from public.members where group_id = g.id and user_id = auth.uid()) then return g; end if;
  if not public.is_team(g.id) and not public.is_pro(auth.uid()) and public.free_group_count() >= 1 then
    raise exception 'free_limit:無料プランで参加できるグループは1つまでです。今のグループを抜けるか、個人プランにしてください。';
  end if;
  insert into public.members (group_id, user_id) values (g.id, auth.uid());
  return g;
end $$;

-- ---------- チャットは有料機能 ----------
drop policy if exists "messages read" on public.messages;
drop policy if exists "messages send" on public.messages;
create policy "messages read" on public.messages for select to authenticated
  using (public.is_member(group_id) and public.has_paid(group_id));
create policy "messages send" on public.messages for insert to authenticated
  with check (public.is_member(group_id) and public.has_paid(group_id) and user_id = auth.uid());

-- ---------- 無料プランは直近30日の記録だけ表示 ----------
drop policy if exists "records read" on public.records;
create policy "records read" on public.records for select to authenticated
  using (public.is_member(group_id) and (public.has_paid(group_id) or created_at > now() - interval '30 days'));

-- ---------- サーバー（決済プログラム）用の権限 ----------
-- 新しいSupabaseプロジェクトでは、管理用の役割にもテーブル権限を明示する必要がある
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant execute on functions to service_role;

notify pgrst, 'reload schema';
