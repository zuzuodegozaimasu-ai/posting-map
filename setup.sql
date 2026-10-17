-- =============================================================
-- 配布マップ 第2版：Supabase の SQL Editor に貼り付けて「Run」（1回だけ）
-- アカウント／グループ／配布記録／チャット
-- ※第1版の records テーブルは削除して作り直します（試作データは消えます）
-- =============================================================

drop table if exists public.areas cascade;
drop table if exists public.records cascade;
drop table if exists public.messages cascade;
drop table if exists public.members cascade;
drop table if exists public.groups cascade;
drop table if exists public.profiles cascade;

-- ---------- プロフィール（表示名） ----------
create table public.profiles (
  id           uuid primary key references auth.users on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 20),
  created_at   timestamptz not null default now()
);

-- アカウント作成時にプロフィールを自動作成
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(nullif(new.raw_user_meta_data->>'display_name',''), split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- グループとメンバー ----------
create table public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 40),
  invite_code text not null unique default substr(md5(random()::text || clock_timestamp()::text), 1, 8),
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now()
);

create table public.members (
  group_id  uuid not null references public.groups on delete cascade,
  user_id   uuid not null references auth.users on delete cascade,
  role      text not null default 'member',
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

-- 自分がそのグループのメンバーか（RLSの再帰を避けるための関数）
create or replace function public.is_member(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where group_id = gid and user_id = auth.uid());
$$;

-- グループ作成（作った人はオーナーとして参加）
create or replace function public.create_group(p_name text) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  insert into public.groups (name, created_by) values (trim(p_name), auth.uid()) returning * into g;
  insert into public.members (group_id, user_id, role) values (g.id, auth.uid(), 'owner');
  return g;
end $$;

-- 招待コードで参加
create or replace function public.join_group(p_code text) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into g from public.groups where invite_code = lower(trim(p_code));
  if g.id is null then raise exception '招待コードが見つかりません'; end if;
  insert into public.members (group_id, user_id) values (g.id, auth.uid()) on conflict do nothing;
  return g;
end $$;

grant execute on function public.create_group(text), public.join_group(text), public.is_member(uuid) to authenticated;

-- ---------- 配布記録 ----------
create table public.records (
  id         uuid primary key,
  group_id   uuid not null references public.groups on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  kind       text not null check (kind in ('done','refuse')),
  count      int  not null default 1 check (count between 0 and 9999),
  note       text check (char_length(note) <= 100),
  lat        double precision not null,
  lng        double precision not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.records (group_id);

-- ---------- チャット ----------
create table public.messages (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references public.groups on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  body       text not null check (char_length(body) between 1 and 500),
  lat        double precision,
  lng        double precision,
  created_at timestamptz not null default now()
);
create index on public.messages (group_id, created_at);

-- ---------- アクセス権（RLS） ----------
alter table public.profiles enable row level security;
alter table public.groups   enable row level security;
alter table public.members  enable row level security;
alter table public.records  enable row level security;
alter table public.messages enable row level security;

create policy "profiles readable" on public.profiles for select to authenticated using (true);
create policy "profiles own update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "groups of mine" on public.groups for select to authenticated using (public.is_member(id));

create policy "members of my groups" on public.members for select to authenticated using (public.is_member(group_id));
create policy "leave group" on public.members for delete to authenticated using (user_id = auth.uid());

create policy "records read" on public.records for select to authenticated using (public.is_member(group_id));
create policy "records add" on public.records for insert to authenticated with check (public.is_member(group_id) and user_id = auth.uid());
create policy "records edit own" on public.records for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "records delete own" on public.records for delete to authenticated using (user_id = auth.uid());

create policy "messages read" on public.messages for select to authenticated using (public.is_member(group_id));
create policy "messages send" on public.messages for insert to authenticated with check (public.is_member(group_id) and user_id = auth.uid());

-- ---------- 配布範囲（手書きで囲んだエリア） ----------
create table if not exists public.areas (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references public.groups on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,  -- 担当者
  name       text check (char_length(name) <= 40),
  points     jsonb not null check (jsonb_typeof(points) = 'array' and jsonb_array_length(points) between 3 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists areas_group_idx on public.areas (group_id);
alter table public.areas enable row level security;
drop policy if exists "areas read" on public.areas;
drop policy if exists "areas add" on public.areas;
drop policy if exists "areas delete" on public.areas;
create policy "areas read" on public.areas for select to authenticated using (public.is_member(group_id));
create policy "areas add" on public.areas for insert to authenticated with check (public.is_member(group_id) and user_id = auth.uid());
-- 消せるのは、描いた本人かグループ作成者
create policy "areas delete" on public.areas for delete to authenticated using (
  user_id = auth.uid()
  or exists (select 1 from public.members m where m.group_id = areas.group_id and m.user_id = auth.uid() and m.role = 'owner')
);
grant select, insert, delete on public.areas to authenticated;

-- ---------- リアルタイム配信 ----------
alter publication supabase_realtime add table public.records, public.messages, public.areas;

-- ---------- アプリ（ログイン済みユーザー）からテーブルを使えるようにする ----------
-- ※実際に見られる範囲は上のRLSで制限されます
grant usage on schema public to authenticated;
grant select on public.profiles, public.groups, public.members to authenticated;
grant update on public.profiles to authenticated;
grant delete on public.members to authenticated;
grant select, insert, update, delete on public.records, public.messages to authenticated;

-- ---------- このSQLより前に作ったアカウントのプロフィールを補完 ----------
insert into public.profiles (id, display_name)
select id, coalesce(nullif(raw_user_meta_data->>'display_name',''), split_part(email,'@',1))
from auth.users
on conflict (id) do nothing;

-- ---------- アプリ側に新しい関数・テーブルをすぐ認識させる ----------
notify pgrst, 'reload schema';
