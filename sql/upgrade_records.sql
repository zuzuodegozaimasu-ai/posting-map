-- =============================================================
-- 配布マップ：記録の項目を増やす
-- 種類の細分化（受け取ってくれた／ポスト投函／お断り／後日改めて）、
-- 場所の名前、配った相手の層、次の予定・TODO
-- 今あるデータは消えません（これまでの「配った」は「ポスト投函」として表示）。
-- SQL Editor に貼り付けて「Run」（1回だけ）
-- =============================================================
alter table public.records drop constraint if exists records_kind_check;
alter table public.records add constraint records_kind_check
  check (kind in ('done','handed','posted','refuse','later'));

alter table public.records add column if not exists place     text check (char_length(place) <= 80);
alter table public.records add column if not exists audience  text[] not null default '{}';
alter table public.records add column if not exists next_date date;
alter table public.records add column if not exists todo      text check (char_length(todo) <= 200);
alter table public.records add column if not exists todo_done boolean not null default false;

notify pgrst, 'reload schema';
