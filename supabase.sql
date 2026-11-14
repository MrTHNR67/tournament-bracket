-- ============================================================
-- التصويت المباشر — مخطط Supabase
-- الصق هذا الملف كاملًا في: Supabase Dashboard → SQL Editor → New query → Run
-- ============================================================
--
-- لتغيير عنوان التصويت: عدّل السطر الذي يحتوي 'التصويت' في جدول settings.
-- للسماح باختيار واحد: max_choices = 1
-- للسماح باختيارين كحد أقصى: max_choices = 2
-- أضف سطرًا برقم جديد لكل خيار إضافي في جدول choices.
-- لتغيير أسماء الخيارات: عدّل label ثم أعد تشغيل الملف؛ سيتم تحديث الأسماء.
-- ============================================================

begin;

create schema if not exists voting_data;
revoke all on schema voting_data from public, anon, authenticated;

create table if not exists voting_data.settings (
  singleton boolean primary key default true check (singleton),
  title text not null check (length(btrim(title)) > 0),
  max_choices integer not null check (max_choices >= 1),
  is_open boolean not null default true,
  version integer not null default 1
);

alter table voting_data.settings
  add column if not exists version integer not null default 1;

create table if not exists voting_data.choices (
  id integer primary key check (id > 0),
  label text not null check (length(btrim(label)) > 0)
);

create table if not exists voting_data.ballots (
  voter_id uuid primary key,
  submitted_at timestamptz not null default now()
);

create table if not exists voting_data.selections (
  voter_id uuid not null references voting_data.ballots(voter_id) on delete cascade,
  choice_id integer not null references voting_data.choices(id),
  primary key (voter_id, choice_id)
);

create index if not exists voting_selections_choice_id_idx
  on voting_data.selections (choice_id);

alter table voting_data.settings enable row level security;
alter table voting_data.choices enable row level security;
alter table voting_data.ballots enable row level security;
alter table voting_data.selections enable row level security;
revoke all on all tables in schema voting_data from public, anon, authenticated;

-- عنوان التصويت وعدد الاختيارات المسموحة.
-- لا نستخدم do update هنا حتى لا نعيد فتح التصويت أو نغيّر الإعدادات عند إعادة التشغيل.
insert into voting_data.settings (singleton, title, max_choices, is_open, version)
values (true, 'التصويت', 1, true, 1)
on conflict (singleton) do nothing;

-- أسماء الخيارات (المتنافسون). بدّلها أو أضف صفًا جديدًا برقم جديد لكل خيار إضافي.
-- مثال لإضافة خيار 17:
--   (17, 'اسم جديد')
insert into voting_data.choices (id, label) values
  (1, 'أمانير'),
  (2, 'حارِس'),
  (3, 'حصين'),
  (4, 'وهّاج'),
  (5, 'SolGuard'),
  (6, 'RayShield'),
  (7, 'Sunova'),
  (8, 'Solvex'),
  (9, 'Panelix'),
  (10, 'Sunora'),
  (11, 'Solvanta'),
  (12, 'Soliva'),
  (13, 'Heliora'),
  (14, 'Solnex'),
  (15, 'سياد'),
  (16, 'مرصدة')
on conflict (id) do update set label = excluded.label;

create or replace function public.get_voting_state()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'title', settings.title,
    'version', settings.version,
    'max_choices', settings.max_choices,
    'is_open', settings.is_open,
    'already_voted', exists (
      select 1 from voting_data.ballots where voter_id = (select auth.uid())
    ),
    'voter_count', (
      select count(*) from voting_data.ballots
    ),
    'my_choices', coalesce((
      select pg_catalog.jsonb_agg(selection.choice_id order by selection.choice_id)
      from voting_data.selections as selection
      where selection.voter_id = (select auth.uid())
    ), '[]'::jsonb),
    'choices', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('id', tally.id, 'label', tally.label, 'votes', tally.votes)
        order by tally.id
      )
      from (
        select choice.id, choice.label, count(selection.choice_id) as votes
        from voting_data.choices as choice
        left join voting_data.selections as selection on selection.choice_id = choice.id
        group by choice.id, choice.label
      ) as tally
    ), '[]'::jsonb)
  )
  from voting_data.settings as settings
  where settings.singleton;
$$;

create or replace function public.submit_voting_ballot(choice_ids integer[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_voter uuid := auth.uid();
  poll_settings voting_data.settings%rowtype;
  selection_count integer := coalesce(pg_catalog.cardinality(choice_ids), 0);
begin
  if current_voter is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  select * into poll_settings from voting_data.settings where singleton for share;
  if not found or not poll_settings.is_open then
    raise exception using errcode = 'P0001', message = 'voting_closed';
  end if;

  if selection_count < 1 or selection_count > poll_settings.max_choices then
    raise exception using errcode = 'P0001', message = 'invalid_choice_count';
  end if;

  if (select count(*) from voting_data.choices where id = any(choice_ids)) <> selection_count then
    raise exception using errcode = 'P0001', message = 'invalid_choices';
  end if;

  insert into voting_data.ballots (voter_id) values (current_voter);
  insert into voting_data.selections (voter_id, choice_id)
  select current_voter, choice_id from pg_catalog.unnest(choice_ids) as selected(choice_id);
end;
$$;

revoke all on function public.get_voting_state() from public, anon, authenticated;
revoke all on function public.submit_voting_ballot(integer[]) from public, anon, authenticated;
grant execute on function public.get_voting_state() to anon, authenticated;
grant execute on function public.submit_voting_ballot(integer[]) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ============================================================
-- أوامر مفيدة (شغّلها منفصلة بعد إنشاء المخطط)
-- ============================================================
--
-- عرض الحالة والنتائج:
-- select public.get_voting_state();
--
-- السماح باختيارين كحد أقصى:
-- update voting_data.settings set max_choices = 2 where singleton;
--
-- إغلاق / فتح التصويت:
-- update voting_data.settings set is_open = false where singleton;
-- update voting_data.settings set is_open = true  where singleton;
--
-- تصفير الأصوات لبدء تصويت جديد (احذف الأصوات وارفع رقم النسخة):
-- delete from voting_data.ballots;
-- update voting_data.settings set version = version + 1 where singleton;
--
-- ملاحظة: التصويت مجهول، لذا من يمسح بيانات المتصفح يمكنه التصويت مرة أخرى.
