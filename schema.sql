-- TURN multiplayer database. Run this complete file in Supabase SQL Editor.

create table if not exists public.game_rooms (
  code text primary key check (code ~ '^[A-Z2-9]{6}$'),
  state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.game_messages (
  id bigint generated always as identity primary key,
  room text not null references public.game_rooms(code) on delete cascade,
  author text not null check (char_length(author) between 1 and 80),
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists game_messages_room_id_idx on public.game_messages(room, id);

create or replace function public.set_game_room_updated_at() returns trigger language plpgsql set search_path='' as $$
begin new.updated_at := now(); return new; end;
$$;
drop trigger if exists game_rooms_set_updated_at on public.game_rooms;
create trigger game_rooms_set_updated_at before update on public.game_rooms for each row execute function public.set_game_room_updated_at();

alter table public.game_rooms enable row level security;
alter table public.game_messages enable row level security;
drop policy if exists "Anyone can read TURN rooms" on public.game_rooms;
create policy "Anyone can read TURN rooms" on public.game_rooms for select to anon using (true);
drop policy if exists "Anyone can create TURN rooms" on public.game_rooms;
create policy "Anyone can create TURN rooms" on public.game_rooms for insert to anon with check (true);
drop policy if exists "Anyone can update TURN rooms" on public.game_rooms;
create policy "Anyone can update TURN rooms" on public.game_rooms for update to anon using (true) with check (true);
drop policy if exists "Anyone can read TURN chat" on public.game_messages;
create policy "Anyone can read TURN chat" on public.game_messages for select to anon using (true);
drop policy if exists "Anyone can post TURN chat" on public.game_messages;
create policy "Anyone can post TURN chat" on public.game_messages for insert to anon with check (true);
grant usage on schema public to anon;
grant select,insert,update on public.game_rooms to anon;
grant select,insert on public.game_messages to anon;
grant usage,select on sequence public.game_messages_id_seq to anon;

-- Realtime replaces constant full-room polling. Only changes to the active
-- room and its chat messages are delivered to connected players.
do $$
begin
  if not exists (select 1 from pg_publication where pubname='supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='game_rooms') then
    alter publication supabase_realtime add table public.game_rooms;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='game_messages') then
    alter publication supabase_realtime add table public.game_messages;
  end if;
end;
$$;

-- The earlier draft returned a table row; remove it before creating the
-- simpler JSON-returning versions below.
drop function if exists public.submit_blind_decision(text,text,boolean);
drop function if exists public.advance_blind_audition(text,text);
drop function if exists public.ensure_blind_round(text,text);
drop function if exists public.resolve_blind_round(text,text);

-- Build an audition inside the shared state. This does not write to the table.
create or replace function public.make_blind_round(p_state jsonb) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb:=p_state; artist jsonb; turns jsonb:='[]'::jsonb; player_count integer; cpu integer; performance integer; full_teams boolean;
begin
  select bool_and(jsonb_array_length(team)=12) into full_teams from jsonb_array_elements(s->'teams') as t(team);
  if coalesce(full_teams,false) then return s; end if;
  artist:=s->'auditionOrder'->coalesce((s->>'auditionIndex')::integer,0);
  player_count:=coalesce((s->>'playerCount')::integer,0);
  performance:=least(99,greatest(35,round(coalesce((artist->>'strength')::numeric,65)*.52+random()*48)::integer));
  for cpu in player_count..3 loop
    if jsonb_array_length(coalesce(s->'teams'->cpu,'[]'::jsonb))<12 and random()<least(.84,greatest(.10,.06+performance*.0078)) then
      turns:=turns||jsonb_build_array(cpu);
    end if;
  end loop;
  return jsonb_set(s,'{blindRound}',jsonb_build_object('artist',artist,'turns',turns,'performance',performance,'decisions','[]'::jsonb),true);
end;
$$;

-- One atomic, row-locked choice per coach. It returns {state, updated_at}.
create or replace function public.submit_blind_decision(p_room text,p_client text,p_turn boolean) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb; r jsonb; turns jsonb; decisions jsonb; artist jsonb; artists jsonb; seat integer; player_count integer; expected_count integer; actual_count integer; winner integer; changed_at timestamptz;
begin
  select state into s from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  select ordinality-1 into seat from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) with ordinality as seats(member,ordinality) where member=p_client limit 1;
  if seat is null then raise exception 'You are not seated in this room'; end if;
  if s->>'blindRound' is null or s->>'pending' is not null then raise exception 'There is no active blind decision'; end if;
  player_count:=coalesce((s->>'playerCount')::integer,0);
  if seat>=player_count or jsonb_array_length(coalesce(s->'teams'->seat,'[]'::jsonb))>=12 then raise exception 'This chair is not eligible'; end if;
  r:=s->'blindRound'; turns:=coalesce(r->'turns','[]'::jsonb); decisions:=coalesce(r->'decisions','[]'::jsonb);
  if not (decisions @> jsonb_build_array(seat)) then
    decisions:=decisions||jsonb_build_array(seat);
    if p_turn and not (turns @> jsonb_build_array(seat)) then turns:=turns||jsonb_build_array(seat); end if;
  end if;
  r:=jsonb_set(jsonb_set(r,'{turns}',turns,true),'{decisions}',decisions,true); s:=jsonb_set(s,'{blindRound}',r,true);
  select count(*) into expected_count from generate_series(0,player_count-1) as seats(n) where jsonb_array_length(coalesce(s->'teams'->n,'[]'::jsonb))<12;
  select count(*) into actual_count from jsonb_array_elements_text(decisions) as choices(n) where n::integer<player_count and jsonb_array_length(coalesce(s->'teams'->(n::integer),'[]'::jsonb))<12;
  if actual_count=expected_count then
    select n::integer into winner from jsonb_array_elements_text(turns) as choices(n) order by random() limit 1;
    artist:=r->'artist';
    if winner is not null then
      artist:=jsonb_set(jsonb_set(artist,'{origin}',to_jsonb(winner),true),'{current}',to_jsonb(winner),true);
      s:=jsonb_set(s,array['teams',winner::text],coalesce(s->'teams'->winner,'[]'::jsonb)||jsonb_build_array(artist),true);
      select jsonb_agg(case when item->>'id'=artist->>'id' then artist else item end order by pos) into artists from jsonb_array_elements(s->'artists') with ordinality as roster(item,pos);
      s:=jsonb_set(s,'{artists}',artists,true);
    end if;
    s:=jsonb_set(s,'{pending}',jsonb_build_object('artist',artist,'turns',turns,'winner',winner,'performance',r->'performance'),true);
    s:=jsonb_set(s,'{blindRound}','null'::jsonb,true);
    s:=jsonb_set(s,'{blindReady}','[]'::jsonb,true);
  end if;
  update public.game_rooms set state=s where code=p_room returning updated_at into changed_at;
  return jsonb_build_object('state',s,'updated_at',changed_at);
end;
$$;

create or replace function public.advance_blind_audition(p_room text,p_client text) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb; next_index integer; roster jsonb; changed_at timestamptz; member_exists boolean;
begin
  select state into s from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  select exists(select 1 from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) as seats(member) where member=p_client) into member_exists;
  if not member_exists then raise exception 'You are not seated in this room'; end if;
  if s->>'pending' is null then raise exception 'This audition is not ready to advance'; end if;
  s:=jsonb_set(s,'{auditions}',coalesce(s->'auditions','[]'::jsonb)||jsonb_build_array(s->'pending'),true);
  s:=jsonb_set(s,'{pending}','null'::jsonb,true);
  next_index:=coalesce((s->>'auditionIndex')::integer,0)+1; roster:=coalesce(s->'auditionOrder','[]'::jsonb);
  if next_index>=jsonb_array_length(roster) then
    select coalesce(jsonb_agg(item order by random()),'[]'::jsonb) into roster from jsonb_array_elements(s->'artists') as all_artists(item) where item->>'origin' is null;
    next_index:=0; s:=jsonb_set(s,'{auditionOrder}',roster,true);
  end if;
  s:=jsonb_set(s,'{auditionIndex}',to_jsonb(next_index),true);
  s:=public.make_blind_round(s);
  update public.game_rooms set state=s where code=p_room returning updated_at into changed_at;
  return jsonb_build_object('state',s,'updated_at',changed_at);
end;
$$;

create or replace function public.ensure_blind_round(p_room text,p_client text) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb; changed_at timestamptz; member_exists boolean;
begin
  select state into s from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  select exists(select 1 from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) as seats(member) where member=p_client) into member_exists;
  if not member_exists then raise exception 'You are not seated in this room'; end if;
  if s->>'pending' is null and s->>'blindRound' is null then
    s:=public.make_blind_round(s);
    update public.game_rooms set state=s where code=p_room returning updated_at into changed_at;
  else
    select updated_at into changed_at from public.game_rooms where code=p_room;
  end if;
  return jsonb_build_object('state',s,'updated_at',changed_at);
end;
$$;

grant execute on function public.make_blind_round(jsonb) to anon;
grant execute on function public.submit_blind_decision(text,text,boolean) to anon;
grant execute on function public.advance_blind_audition(text,text) to anon;
grant execute on function public.ensure_blind_round(text,text) to anon;

-- A player may leave the result screen at their own pace. The next audition
-- begins only after every occupied human chair has marked itself ready.
create or replace function public.mark_blind_result_ready(p_room text,p_client text) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb; ready jsonb; expected_count integer; ready_count integer; changed_at timestamptz; member_exists boolean;
begin
  select state into s from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  select exists(select 1 from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) as seats(member) where member=p_client) into member_exists;
  if not member_exists then raise exception 'You are not seated in this room'; end if;
  -- A second browser can finish the shared result gate just before this
  -- request arrives. Return that newer room state instead of leaving the
  -- player stranded behind an avoidable error.
  if s->>'pending' is null then
    return jsonb_build_object('state',s,'updated_at',(select updated_at from public.game_rooms where code=p_room));
  end if;
  ready:=coalesce(s->'blindReady','[]'::jsonb);
  if not (ready @> jsonb_build_array(p_client)) then ready:=ready||jsonb_build_array(p_client); end if;
  s:=jsonb_set(s,'{blindReady}',ready,true);
  -- A coach whose team is full is no longer taking part in Blind decisions.
  -- Do not make the remaining coach wait on that finished team before the
  -- next audition can be presented.
  select count(*) into expected_count
    from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) with ordinality as seats(member,ordinality)
    where member is not null
      and jsonb_array_length(coalesce(s->'teams'->((ordinality-1)::integer),'[]'::jsonb))<12;
  select count(*) into ready_count
    from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) with ordinality as seats(member,ordinality)
    where member is not null
      and jsonb_array_length(coalesce(s->'teams'->((ordinality-1)::integer),'[]'::jsonb))<12
      and ready @> jsonb_build_array(member);
  update public.game_rooms set state=s where code=p_room returning updated_at into changed_at;
  if ready_count>=expected_count then return public.advance_blind_audition(p_room,p_client); end if;
  return jsonb_build_object('state',s,'updated_at',changed_at);
end;
$$;

-- Reveals CPU-only turns when all human teams are full.
create or replace function public.reveal_cpu_blind_turns(p_room text,p_client text) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb; r jsonb; turns jsonb; artist jsonb; artists jsonb; winner integer; changed_at timestamptz;
begin
  select state into s from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  if not exists(select 1 from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) as seats(member) where member=p_client) then raise exception 'You are not seated in this room'; end if;
  if s->>'blindRound' is null or s->>'pending' is not null then raise exception 'No CPU turn result is waiting'; end if;
  r:=s->'blindRound'; turns:=coalesce(r->'turns','[]'::jsonb); select n::integer into winner from jsonb_array_elements_text(turns) as choices(n) order by random() limit 1;
  artist:=r->'artist';
  if winner is not null then
    artist:=jsonb_set(jsonb_set(artist,'{origin}',to_jsonb(winner),true),'{current}',to_jsonb(winner),true);
    s:=jsonb_set(s,array['teams',winner::text],coalesce(s->'teams'->winner,'[]'::jsonb)||jsonb_build_array(artist),true);
    select jsonb_agg(case when item->>'id'=artist->>'id' then artist else item end order by pos) into artists from jsonb_array_elements(s->'artists') with ordinality as roster(item,pos);
    s:=jsonb_set(s,'{artists}',artists,true);
  end if;
  s:=jsonb_set(s,'{pending}',jsonb_build_object('artist',artist,'turns',turns,'winner',winner,'performance',r->'performance'),true);
  s:=jsonb_set(s,'{blindRound}','null'::jsonb,true); s:=jsonb_set(s,'{blindReady}','[]'::jsonb,true);
  update public.game_rooms set state=s where code=p_room returning updated_at into changed_at;
  return jsonb_build_object('state',s,'updated_at',changed_at);
end;
$$;

grant execute on function public.mark_blind_result_ready(text,text) to anon;
grant execute on function public.reveal_cpu_blind_turns(text,text) to anon;

-- Atomic acknowledgements for Battle and Knockout result screens.  Two
-- browsers can press a button at once without one acknowledgement replacing
-- the other in the room JSON.
create or replace function public.submit_round_response(
  p_room text,
  p_client text,
  p_action text,
  p_wants_steal boolean default false
) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb; f jsonb; ready jsonb; required jsonb; human jsonb; stealers jsonb; seat integer; changed_at timestamptz;
begin
  select state into s from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  select ordinality-1 into seat
    from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) with ordinality as seats(member,ordinality)
    where member=p_client limit 1;
  if seat is null then raise exception 'You are not seated in this room'; end if;
  f:=s->'roundFlow';
  if f is null then raise exception 'No round decision is active'; end if;
  ready:=coalesce(f->'ready','[]'::jsonb);

  if p_action='show_winner' then
    -- Both human browsers may press Show Winner at virtually the same time.
    -- If the final acknowledgement already advanced the shared flow, a late
    -- in-flight click is a harmless duplicate, not an error for that player.
    if f->>'stage' not in ('winner-choice','show-winner') then
      if f->>'stage' in ('steal-choice','show-steal','reveal') then
        return jsonb_build_object('state',s,'updated_at',(select updated_at from public.game_rooms where code=p_room));
      end if;
      raise exception 'The winner is not ready to show';
    end if;
    required:=coalesce(f->'required','[]'::jsonb);
    if not (required @> jsonb_build_array(seat)) then raise exception 'This coach does not need to show the winner'; end if;
  elsif p_action='show_steal' then
    if f->>'stage'<>'show-steal' then raise exception 'The steal is not ready to show'; end if;
    required:=coalesce(f->'required','[]'::jsonb);
    if not (required @> jsonb_build_array(seat)) then raise exception 'This coach does not need to show the steal'; end if;
  elsif p_action='next_round' then
    if f->>'stage'<>'reveal' then raise exception 'The round result is not ready to advance'; end if;
    required:=jsonb_build_array(0,1,2,3);
    if seat>=coalesce((s->>'playerCount')::integer,0) then raise exception 'This chair is not human-controlled'; end if;
  elsif p_action='steal' then
    if f->>'stage'<>'steal-choice' then raise exception 'No steal decision is active'; end if;
    human:=coalesce(f->'human','[]'::jsonb);
    if not (human @> jsonb_build_array(seat)) then raise exception 'This coach is not eligible to steal'; end if;
    if p_wants_steal then
      stealers:=coalesce(f#>'{entry,stealers}','[]'::jsonb);
      if not (stealers @> jsonb_build_array(seat)) then stealers:=stealers||jsonb_build_array(seat); end if;
      f:=jsonb_set(f,'{entry,stealers}',stealers,true);
    end if;
  else
    raise exception 'Unknown round action';
  end if;

  if not (ready @> jsonb_build_array(seat)) then ready:=ready||jsonb_build_array(seat); end if;
  f:=jsonb_set(f,'{ready}',ready,true);
  s:=jsonb_set(s,'{roundFlow}',f,true);
  update public.game_rooms set state=s where code=p_room returning updated_at into changed_at;
  return jsonb_build_object('state',s,'updated_at',changed_at);
end;
$$;

grant execute on function public.submit_round_response(text,text,text,boolean) to anon;

-- A human winner choice and the other coaches' Show Winner clicks can happen
-- in either order. Lock the chosen winner into the room before the reveal.
create or replace function public.submit_round_winner(p_room text,p_client text,p_winner integer) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb; f jsonb; entry jsonb; winner jsonb; loser jsonb; revised_artists jsonb; seat integer; changed_at timestamptz; result_key text[];
begin
  select state into s from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  select ordinality-1 into seat
    from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) with ordinality as seats(member,ordinality)
    where member=p_client limit 1;
  if seat is null then raise exception 'You are not seated in this room'; end if;
  f:=s->'roundFlow';
  if f is null or f->>'stage'<>'winner-choice' or coalesce((f->>'winnerChosen')::boolean,false) then
    raise exception 'No human winner choice is active';
  end if;
  entry:=f->'entry';
  if seat<>(entry->>'coach')::integer then raise exception 'Only the battle coach can choose this winner'; end if;
  if p_winner=(entry->'a'->>'id')::integer then winner:=entry->'a'; loser:=entry->'b';
  elsif p_winner=(entry->'b'->>'id')::integer then winner:=entry->'b'; loser:=entry->'a';
  else raise exception 'That artist is not in this matchup'; end if;
  entry:=jsonb_set(entry,'{winner}',winner,true);
  entry:=jsonb_set(entry,'{loser}',loser,true);
  entry:=jsonb_set(entry,'{stealers}','[]'::jsonb,true);
  entry:=jsonb_set(entry,'{outcome}','""'::jsonb,true);
  f:=jsonb_set(f,'{entry}',entry,true);
  f:=jsonb_set(f,'{winnerChosen}','true'::jsonb,true);
  s:=jsonb_set(s,'{roundFlow}',f,true);
  select jsonb_agg(case when (artist->>'id')::integer=(loser->>'id')::integer
    then jsonb_set(artist,'{status}',to_jsonb((case when f->>'round'='battle' then 'battle-elim' else 'knockout-elim' end)::text),true)
    else artist end order by ordinality) into revised_artists
    from jsonb_array_elements(coalesce(s->'artists','[]'::jsonb)) with ordinality as artists(artist,ordinality);
  s:=jsonb_set(s,'{artists}',coalesce(revised_artists,'[]'::jsonb),true);
  result_key:=case when f->>'round'='battle' then '{battleLog}'::text[] else '{koLog}'::text[] end;
  s:=jsonb_set(s,result_key,coalesce(s#>result_key,'[]'::jsonb)||jsonb_build_array(entry),true);
  update public.game_rooms set state=s where code=p_room returning updated_at into changed_at;
  return jsonb_build_object('state',s,'updated_at',changed_at);
end;
$$;

grant execute on function public.submit_round_winner(text,text,integer) to anon;

-- Emergency recovery for a test/debug session. This deliberately skips the
-- remaining decision screens for the current Battle or Knockout, records a
-- random winner, and presents the next matchup. It is row-locked so every
-- browser receives the same recovery state instead of trying to escape the
-- stalled round independently.
create or replace function public.force_round_end(p_room text,p_client text) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb; f jsonb; entry jsonb; winner jsonb; loser jsonb; revised_artists jsonb; seat integer; round_name text; queue_key text; index_key text; log_key text[]; round_index integer; changed_at timestamptz;
begin
  select state into s from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  select ordinality-1 into seat
    from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) with ordinality as seats(member,ordinality)
    where member=p_client limit 1;
  if seat is null then raise exception 'You are not seated in this room'; end if;

  f:=s->'roundFlow';
  round_name:=coalesce(f->>'round',case when s->>'screen'='battleArea' then 'battle' when s->>'screen'='knockoutArea' then 'knockout' else null end);
  if round_name is null or round_name not in ('battle','knockout') then raise exception 'There is no Battle or Knockout to force forward'; end if;
  queue_key:=case when round_name='battle' then 'battleQueue' else 'koQueue' end;
  index_key:=case when round_name='battle' then 'battleIndex' else 'koIndex' end;
  log_key:=case when round_name='battle' then '{battleLog}'::text[] else '{koLog}'::text[] end;
  round_index:=coalesce((s->>index_key)::integer,0);
  entry:=coalesce(f->'entry',s->queue_key->round_index);
  if entry is null then raise exception 'There is no matchup to force forward'; end if;

  if entry->'winner' is not null then winner:=entry->'winner'; loser:=entry->'loser';
  elsif random()<.5 then winner:=entry->'a'; loser:=entry->'b';
  else winner:=entry->'b'; loser:=entry->'a'; end if;
  entry:=jsonb_set(entry,'{winner}',winner,true);
  entry:=jsonb_set(entry,'{loser}',loser,true);
  entry:=jsonb_set(entry,'{stealers}','[]'::jsonb,true);
  entry:=jsonb_set(entry,'{stealResolved}','true'::jsonb,true);
  entry:=jsonb_set(entry,'{outcome}',to_jsonb((loser->>'name')||' was eliminated by Force Round End.'),true);
  select jsonb_agg(case when (artist->>'id')::integer=(loser->>'id')::integer
    then jsonb_set(artist,'{status}',to_jsonb((case when round_name='battle' then 'battle-elim' else 'knockout-elim' end)::text),true)
    else artist end order by ordinality) into revised_artists
    from jsonb_array_elements(coalesce(s->'artists','[]'::jsonb)) with ordinality as artists(artist,ordinality);
  s:=jsonb_set(s,'{artists}',coalesce(revised_artists,'[]'::jsonb),true);
  s:=jsonb_set(s,log_key,coalesce(s#>log_key,'[]'::jsonb)||jsonb_build_array(entry),true);
  s:=jsonb_set(s,array[index_key],to_jsonb(round_index+1),true);
  s:=jsonb_set(s,'{roundFlow}','null'::jsonb,true);
  update public.game_rooms set state=s where code=p_room returning updated_at into changed_at;
  return jsonb_build_object('state',s,'updated_at',changed_at);
end;
$$;

grant execute on function public.force_round_end(text,text) to anon;

-- Result-show checkpoints use the same row lock so every coach's reveal click
-- is retained when they press together.
create or replace function public.submit_live_checkpoint(p_room text,p_client text) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb; f jsonb; ready jsonb; required jsonb; seat integer; changed_at timestamptz; claimed boolean:=false;
begin
  select state into s from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  select ordinality-1 into seat
    from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) with ordinality as seats(member,ordinality)
    where member=p_client limit 1;
  if seat is null then raise exception 'You are not seated in this room'; end if;
  f:=s->'liveFlow';
  if f is null then raise exception 'No live result checkpoint is active'; end if;
  -- A late click can arrive just after another coach claimed the transition.
  -- Return the current state quietly; the caller will render the new result.
  if f->>'stage'='executing' then
    return jsonb_build_object('state',s,'updated_at',(select updated_at from public.game_rooms where code=p_room),'claimed',false);
  end if;
  if f->>'stage'<>'checkpoint' then raise exception 'No live result checkpoint is active'; end if;
  required:=coalesce(f->'required','[]'::jsonb);
  if not (required @> jsonb_build_array(seat)) then raise exception 'This coach is not required for this reveal'; end if;
  ready:=coalesce(f->'ready','[]'::jsonb);
  if not (ready @> jsonb_build_array(seat)) then ready:=ready||jsonb_build_array(seat); end if;
  f:=jsonb_set(f,'{ready}',ready,true);
  -- The final required click claims the transition. Only that client may
  -- calculate and save the next result, so simultaneous browsers cannot
  -- reveal the same result twice with conflicting random score updates.
  if ready @> required then
    f:=jsonb_set(f,'{stage}','"executing"'::jsonb,true);
    claimed:=true;
  end if;
  s:=jsonb_set(s,'{liveFlow}',f,true);
  update public.game_rooms set state=s where code=p_room returning updated_at into changed_at;
  return jsonb_build_object('state',s,'updated_at',changed_at,'claimed',claimed);
end;
$$;

grant execute on function public.submit_live_checkpoint(text,text) to anon;

-- The human playoff save is also a locked transition. The coach's selection
-- creates the shared reveal checkpoint atomically, so it cannot be lost to a
-- refresh or a simultaneous room update.
create or replace function public.submit_live_save(p_room text,p_client text,p_artist integer) returns jsonb language plpgsql set search_path='' as $$
declare s jsonb; f jsonb; seat integer; team integer; required jsonb; changed_at timestamptz; claimed boolean:=false;
begin
  select state into s from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  select ordinality-1 into seat
    from jsonb_array_elements_text(coalesce(s->'roomSeats','[]'::jsonb)) with ordinality as seats(member,ordinality)
    where member=p_client limit 1;
  if seat is null then raise exception 'You are not seated in this room'; end if;
  f:=s->'liveFlow';
  if f is null or f->>'mode'<>'playoff' or f->>'stage'<>'save-choice' then
    raise exception 'No coach save is waiting for a decision';
  end if;
  team:=(f->>'team')::integer;
  if seat<>team then raise exception 'Only this team''s coach can make the save'; end if;
  if not exists (
    select 1 from jsonb_array_elements(coalesce(s->'playoffData','[]'::jsonb)) as teams(roster),
      jsonb_array_elements(teams.roster) as contestant(item)
    where contestant.item->'artist'->>'id'=p_artist::text and (contestant.item->>'team')::integer=team and coalesce((contestant.item->>'public')::boolean,false)=false
  ) then raise exception 'That artist is not eligible for this save'; end if;
  select coalesce(jsonb_agg(n order by n),'[]'::jsonb) into required
    from generate_series(0,greatest(coalesce((s->>'playerCount')::integer,1)-1,0)) as seats(n)
    where n<>team;
  f:=jsonb_set(f,'{stage}','"checkpoint"'::jsonb,true);
  f:=jsonb_set(f,'{action}','"playoff-save"'::jsonb,true);
  f:=jsonb_set(f,'{label}','"REVEAL RESULT"'::jsonb,true);
  f:=jsonb_set(f,'{required}',required,true);
  f:=jsonb_set(f,'{ready}','[]'::jsonb,true);
  f:=jsonb_set(f,'{saveArtistId}',to_jsonb(p_artist),true);
  if required='[]'::jsonb then
    f:=jsonb_set(f,'{stage}','"executing"'::jsonb,true);
    claimed:=true;
  end if;
  s:=jsonb_set(s,'{liveFlow}',f,true);
  update public.game_rooms set state=s where code=p_room returning updated_at into changed_at;
  return jsonb_build_object('state',s,'updated_at',changed_at,'claimed',claimed);
end;
$$;

grant execute on function public.submit_live_save(text,text,integer) to anon;
