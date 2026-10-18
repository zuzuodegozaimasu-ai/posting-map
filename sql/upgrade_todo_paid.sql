-- =============================================================
-- 配布マップ：次の予定・TODOを有料プランの機能にする
-- 予定（次に行く日・やること）を新しく入れられるのは有料プランのときだけ。
-- 無料に戻った人も、すでにある予定はそのまま残り、記録の編集はできる。
-- 今あるデータは消えません。SQL Editor に貼り付けて「Run」（1回だけ）
-- =============================================================
drop policy if exists "records add" on public.records;
create policy "records add" on public.records for insert to authenticated
  with check (
    public.is_member(group_id) and user_id = auth.uid()
    and (public.has_paid(group_id) or (next_date is null and todo is null))
  );

drop policy if exists "records edit own" on public.records;
create policy "records edit own" on public.records for update to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and (
      public.has_paid(group_id)
      or (next_date is null and todo is null)
      or exists (  -- 無料のときは、すでにある予定を変えない編集だけOK
        select 1 from public.records old
        where old.id = records.id
          and old.next_date is not distinct from records.next_date
          and old.todo is not distinct from records.todo
      )
    )
  );

notify pgrst, 'reload schema';
