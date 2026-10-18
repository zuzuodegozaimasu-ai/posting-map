-- =============================================================
-- 配布マップ：チャットの無料／有料の切り替え
-- 無料：定型文だけ送れる（読むのは全員OK）／有料：自由に文字を打てる
-- 今あるデータは消えません。SQL Editor に貼り付けて「Run」（1回だけ）
-- ※アプリの定型文（PHRASES）を変えたら、ここも同じ文に揃える
-- =============================================================

create or replace function public.is_preset_message(p_body text) returns boolean
language sql immutable as $$
  select p_body in (
    'こっちに来てください',
    '今ここにいます',
    'このエリア終わりました',
    'チラシが足りません',
    '休憩します',
    '戻ります'
  );
$$;
grant execute on function public.is_preset_message(text) to authenticated, service_role;

drop policy if exists "messages read" on public.messages;
drop policy if exists "messages send" on public.messages;
create policy "messages read" on public.messages for select to authenticated
  using (public.is_member(group_id));
create policy "messages send" on public.messages for insert to authenticated
  with check (
    public.is_member(group_id) and user_id = auth.uid()
    and (public.has_paid(group_id) or public.is_preset_message(body))
  );

notify pgrst, 'reload schema';
