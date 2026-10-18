-- =============================================================
-- 配布マップ：プロフィールにアイコンと色を追加
-- 今あるデータは消えません。SQL Editor に貼り付けて「Run」（1回だけ）
-- =============================================================
alter table public.profiles add column if not exists avatar text check (char_length(avatar) <= 8);
alter table public.profiles add column if not exists color text check (color ~ '^#[0-9a-fA-F]{6}$');
grant select, update on public.profiles to authenticated;
drop policy if exists "profiles own update" on public.profiles;
create policy "profiles own update" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
notify pgrst, 'reload schema';
