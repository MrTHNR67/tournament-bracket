-- ============================================================
-- بطولة المواجهات (جولات) — مخطط Supabase
-- الصق هذا الملف في: Supabase Dashboard → SQL Editor → New query → Run
-- ============================================================

begin;

create schema if not exists tournament_data;
revoke all on schema tournament_data from public, anon, authenticated;

create table if not exists tournament_data.settings (
  singleton boolean primary key default true check (singleton),
  title text not null default 'بطولة المواجهات',
  admin_token text not null default 'admin',
  status text not null default 'idle' check (status in ('idle','active','finished')),
  current_round integer not null default 0,
  champion_id integer,
  version integer not null default 1
);

create table if not exists tournament_data.participants (
  id serial primary key,
  name text not null,
  seed integer not null,
  eliminated boolean not null default false
);

create table if not exists tournament_data.matchups (
  id serial primary key,
  round_number integer not null,
  slot integer not null,
  participant_a_id integer references tournament_data.participants(id),
  participant_b_id integer references tournament_data.participants(id),
  status text not null default 'pending' check (status in ('pending','voting','closed')),
  winner_id integer references tournament_data.participants(id),
  created_at timestamptz not null default now()
);

create table if not exists tournament_data.votes (
  matchup_id integer not null references tournament_data.matchups(id) on delete cascade,
  voter_id uuid not null,
  participant_id integer not null references tournament_data.participants(id),
  created_at timestamptz not null default now(),
  primary key (matchup_id, voter_id)
);

create index if not exists tournament_matchups_round_idx on tournament_data.matchups(round_number);
create index if not exists tournament_votes_matchup_idx on tournament_data.votes(matchup_id);

alter table tournament_data.settings enable row level security;
alter table tournament_data.participants enable row level security;
alter table tournament_data.matchups enable row level security;
alter table tournament_data.votes enable row level security;
revoke all on all tables in schema tournament_data from public, anon, authenticated;

insert into tournament_data.settings (singleton) values (true) on conflict (singleton) do nothing;

-- ---------- get state ----------
create or replace function public.get_tournament_state()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with tallies as (
    select matchup_id, pg_catalog.jsonb_object_agg(participant_id::text, cnt) as votes
    from (
      select matchup_id, participant_id, count(*)::int as cnt
      from tournament_data.votes
      group by matchup_id, participant_id
    ) x
    group by matchup_id
  ),
  tally_map as (
    select coalesce(pg_catalog.jsonb_object_agg(matchup_id::text, votes), '{}'::jsonb) as obj
    from tallies
  ),
  my_votes as (
    select coalesce(pg_catalog.jsonb_object_agg(matchup_id::text, participant_id::text), '{}'::jsonb) as obj
    from tournament_data.votes
    where voter_id = (select auth.uid())
  )
  select pg_catalog.jsonb_build_object(
    'title', s.title,
    'status', s.status,
    'current_round', s.current_round,
    'champion_id', s.champion_id,
    'version', s.version,
    'admin_token_set', (s.admin_token is not null),
    'participants', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', p.id, 'name', p.name, 'eliminated', p.eliminated) order by p.seed)
      from tournament_data.participants as p
    ), '[]'::jsonb),
    'matchups', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', m.id, 'round', m.round_number, 'slot', m.slot, 'a', m.participant_a_id, 'b', m.participant_b_id, 'status', m.status, 'winner', m.winner_id) order by m.round_number, m.slot)
      from tournament_data.matchups as m
    ), '[]'::jsonb),
    'tallies', (select obj from tally_map),
    'my_votes', (select obj from my_votes)
  )
  from tournament_data.settings as s
  where s.singleton;
$$;

-- ---------- cast vote ----------
create or replace function public.cast_tournament_vote(p_matchup_id integer, p_participant_id integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_voter uuid := auth.uid();
  v_matchup tournament_data.matchups%rowtype;
begin
  if v_voter is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  select * into v_matchup from tournament_data.matchups where id = p_matchup_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'invalid_matchup';
  end if;
  if v_matchup.status <> 'voting' then
    raise exception using errcode = 'P0001', message = 'voting_closed';
  end if;
  if p_participant_id is distinct from v_matchup.participant_a_id
     and p_participant_id is distinct from v_matchup.participant_b_id then
    raise exception using errcode = 'P0001', message = 'invalid_participant';
  end if;
  insert into tournament_data.votes (matchup_id, voter_id, participant_id)
  values (p_matchup_id, v_voter, p_participant_id);
end;
$$;

-- ---------- admin: reset tournament ----------
create or replace function public.admin_reset_tournament(p_admin_token text, p_names text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
begin
  select admin_token into v_token from tournament_data.settings where singleton for update;
  if v_token is null then
    insert into tournament_data.settings (singleton, admin_token) values (true, p_admin_token)
    on conflict (singleton) do update set admin_token = excluded.admin_token;
    select admin_token into v_token from tournament_data.settings where singleton;
  end if;
  if v_token is distinct from p_admin_token then
    raise exception using errcode = '42501', message = 'invalid_admin_token';
  end if;

  delete from tournament_data.votes;
  delete from tournament_data.matchups;
  delete from tournament_data.participants;

  insert into tournament_data.participants (name, seed)
  select name, ord from pg_catalog.unnest(p_names) with ordinality as t(name, ord);

  insert into tournament_data.matchups (round_number, slot, participant_a_id, participant_b_id, status)
  select 1, (a.seed + 1) / 2, a.id, b.id, 'voting'
  from tournament_data.participants as a
  left join tournament_data.participants as b on b.seed = a.seed + 1
  where a.seed % 2 = 1;

  update tournament_data.matchups
  set status = 'closed', winner_id = participant_a_id
  where participant_b_id is null;

  update tournament_data.settings
  set status = 'active', current_round = 1, champion_id = null, version = version + 1
  where singleton;
end;
$$;

-- ---------- admin: close matchup ----------
create or replace function public.admin_close_matchup(p_admin_token text, p_matchup_id integer, p_winner_id integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
  v_matchup tournament_data.matchups%rowtype;
  v_loser integer;
begin
  select admin_token into v_token from tournament_data.settings where singleton;
  if v_token is null or v_token is distinct from p_admin_token then
    raise exception using errcode = '42501', message = 'invalid_admin_token';
  end if;
  select * into v_matchup from tournament_data.matchups where id = p_matchup_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'invalid_matchup';
  end if;
  if p_winner_id is distinct from v_matchup.participant_a_id
     and (v_matchup.participant_b_id is null or p_winner_id is distinct from v_matchup.participant_b_id) then
    raise exception using errcode = 'P0001', message = 'invalid_winner';
  end if;

  update tournament_data.matchups
  set status = 'closed', winner_id = p_winner_id
  where id = p_matchup_id;

  if v_matchup.participant_b_id is not null then
    if p_winner_id = v_matchup.participant_a_id then
      v_loser := v_matchup.participant_b_id;
    else
      v_loser := v_matchup.participant_a_id;
    end if;
    update tournament_data.participants set eliminated = true where id = v_loser;
  end if;
end;
$$;

-- ---------- admin: reopen matchup ----------
create or replace function public.admin_reopen_matchup(p_admin_token text, p_matchup_id integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
begin
  select admin_token into v_token from tournament_data.settings where singleton;
  if v_token is null or v_token is distinct from p_admin_token then
    raise exception using errcode = '42501', message = 'invalid_admin_token';
  end if;
  update tournament_data.matchups set status = 'voting', winner_id = null where id = p_matchup_id;
end;
$$;

-- ---------- admin: advance round ----------
create or replace function public.admin_advance_round(p_admin_token text, p_round_number integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
  v_current integer;
  v_winners integer[];
  v_count integer;
  i integer;
begin
  select admin_token, current_round into v_token, v_current from tournament_data.settings where singleton;
  if v_token is null or v_token is distinct from p_admin_token then
    raise exception using errcode = '42501', message = 'invalid_admin_token';
  end if;
  if p_round_number is distinct from v_current then
    raise exception using errcode = 'P0001', message = 'invalid_round';
  end if;
  if exists (
    select 1 from tournament_data.matchups
    where round_number = p_round_number and status <> 'closed'
  ) then
    raise exception using errcode = 'P0001', message = 'round_not_finished';
  end if;

  select array_agg(winner_id order by slot) into v_winners
  from tournament_data.matchups
  where round_number = p_round_number;

  if v_winners is null then
    select array_agg(id order by seed) into v_winners
    from tournament_data.participants
    where eliminated = false;
  end if;

  v_count := coalesce(array_length(v_winners, 1), 0);

  if v_count <= 1 then
    update tournament_data.settings
    set status = 'finished', champion_id = v_winners[1], version = version + 1
    where singleton;
    return;
  end if;

  i := 1;
  while i <= v_count loop
    insert into tournament_data.matchups (round_number, slot, participant_a_id, participant_b_id, status)
    values (
      p_round_number + 1,
      (i + 1) / 2,
      v_winners[i],
      case when i + 1 <= v_count then v_winners[i + 1] else null end,
      'voting'
    );
    if i + 1 > v_count then
      update tournament_data.matchups
      set status = 'closed', winner_id = v_winners[i]
      where id = (select max(id) from tournament_data.matchups);
    end if;
    i := i + 2;
  end loop;

  update tournament_data.settings
  set current_round = p_round_number + 1, version = version + 1
  where singleton;
end;
$$;

revoke all on function public.get_tournament_state() from public, anon, authenticated;
revoke all on function public.cast_tournament_vote(integer, integer) from public, anon, authenticated;
revoke all on function public.admin_reset_tournament(text, text[]) from public, anon, authenticated;
revoke all on function public.admin_close_matchup(text, integer, integer) from public, anon, authenticated;
revoke all on function public.admin_reopen_matchup(text, integer) from public, anon, authenticated;
revoke all on function public.admin_advance_round(text, integer) from public, anon, authenticated;

grant execute on function public.get_tournament_state() to anon, authenticated;
grant execute on function public.cast_tournament_vote(integer, integer) to authenticated;
grant execute on function public.admin_reset_tournament(text, text[]) to anon, authenticated;
grant execute on function public.admin_close_matchup(text, integer, integer) to anon, authenticated;
grant execute on function public.admin_reopen_matchup(text, integer) to anon, authenticated;
grant execute on function public.admin_advance_round(text, integer) to anon, authenticated;

notify pgrst, 'reload schema';
commit;
