-- TURN multiplayer setup
-- Run this whole file once in Supabase: SQL Editor → New query → Run.

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

create index if not exists game_messages_room_id_idx
  on public.game_messages (room, id);

-- Keep the value polled by index.html current whenever a room is saved.
create or replace function public.set_game_room_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists game_rooms_set_updated_at on public.game_rooms;
create trigger game_rooms_set_updated_at
before update on public.game_rooms
for each row execute function public.set_game_room_updated_at();

alter table public.game_rooms enable row level security;
alter table public.game_messages enable row level security;

-- The current app is a static, no-sign-in game. Its browser sends the anon key,
-- so these policies deliberately permit public room sharing. Do not put private
-- information in the saved game state or chat.
drop policy if exists "Anyone can read TURN rooms" on public.game_rooms;
create policy "Anyone can read TURN rooms"
on public.game_rooms for select
to anon
using (true);

drop policy if exists "Anyone can create TURN rooms" on public.game_rooms;
create policy "Anyone can create TURN rooms"
on public.game_rooms for insert
to anon
with check (true);

drop policy if exists "Anyone can update TURN rooms" on public.game_rooms;
create policy "Anyone can update TURN rooms"
on public.game_rooms for update
to anon
using (true)
with check (true);

drop policy if exists "Anyone can read TURN chat" on public.game_messages;
create policy "Anyone can read TURN chat"
on public.game_messages for select
to anon
using (true);

drop policy if exists "Anyone can post TURN chat" on public.game_messages;
create policy "Anyone can post TURN chat"
on public.game_messages for insert
to anon
with check (true);

grant usage on schema public to anon;
grant select, insert, update on public.game_rooms to anon;
grant select, insert on public.game_messages to anon;
grant usage, select on sequence public.game_messages_id_seq to anon;

-- Atomic blind-audition actions. These prevent simultaneous browser saves from
-- overwriting another coach's choice.
create or replace function public.submit_blind_decision(p_room text, p_client text, p_turn boolean)
returns public.game_rooms language plpgsql security invoker set search_path = '' as $$
declare v_room public.game_rooms; v_state jsonb; v_round jsonb; v_seat integer; v_player_count integer; v_turns jsonb; v_decisions jsonb; v_expected integer; v_actual integer; v_winner integer; v_artist jsonb; v_artists jsonb;
begin
  select * into v_room from public.game_rooms where code = p_room for update;
  if not found then raise exception 'Room not found'; end if;
  v_state := v_room.state;
  select ordinal - 1 into v_seat from jsonb_array_elements_text(coalesce(v_state->'roomSeats','[]'::jsonb)) with ordinality as seats(member,ordinal) where member = p_client limit 1;
  if v_seat is null then raise exception 'You are not seated in this room'; end if;
  v_round := v_state->'blindRound';
  if v_round is null or v_state->'pending' is not null then raise exception 'There is no active blind decision'; end if;
  v_player_count := coalesce((v_state->>'playerCount')::integer,0);
  if v_seat >= v_player_count or jsonb_array_length(coalesce(v_state->'teams'->v_seat,'[]'::jsonb)) >= 12 then raise exception 'This chair is not eligible'; end if;
  v_turns := coalesce(v_round->'turns','[]'::jsonb); v_decisions := coalesce(v_round->'decisions','[]'::jsonb);
  if not v_decisions @> jsonb_build_array(v_seat) then
    v_decisions := v_decisions || jsonb_build_array(v_seat);
    if p_turn and not v_turns @> jsonb_build_array(v_seat) then v_turns := v_turns || jsonb_build_array(v_seat); end if;
  end if;
  v_round := jsonb_set(jsonb_set(v_round,'{turns}',v_turns),'{decisions}',v_decisions);
  v_state := jsonb_set(v_state,'{blindRound}',v_round);
  select count(*) into v_expected from generate_series(0,v_player_count-1) as seats(k) where jsonb_array_length(coalesce(v_state->'teams'->(seats.k),'[]'::jsonb)) < 12;
  select count(*) into v_actual from jsonb_array_elements_text(v_decisions) as decisions(value) where (decisions.value)::integer < v_player_count and jsonb_array_length(coalesce(v_state->'teams'->((decisions.value)::integer),'[]'::jsonb)) < 12;
  if v_expected = v_actual then
    select (value #>> '{}')::integer into v_winner from jsonb_array_elements(v_turns) order by random() limit 1;
    v_artist := v_round->'artist';
    if v_winner is not null then
      v_artist := jsonb_set(jsonb_set(v_artist,'{origin}',to_jsonb(v_winner)),'{current}',to_jsonb(v_winner));
      v_state := jsonb_set(v_state,array['teams',v_winner::text],coalesce(v_state->'teams'->v_winner,'[]'::jsonb)||jsonb_build_array(v_artist));
      select jsonb_agg(case when (artist->>'id')::integer=(v_artist->>'id')::integer then v_artist else artist end order by ordinal) into v_artists from jsonb_array_elements(v_state->'artists') with ordinality as roster(artist,ordinal);
      v_state := jsonb_set(v_state,'{artists}',v_artists);
    end if;
    v_state := jsonb_set(v_state,'{pending}',jsonb_build_object('artist',v_artist,'turns',v_turns,'winner',v_winner,'performance',v_round->'performance'));
    v_state := jsonb_set(v_state,'{blindRound}','null'::jsonb);
  end if;
  update public.game_rooms set state=v_state where code=p_room returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.resolve_blind_round(p_room text, p_client text)
returns public.game_rooms language plpgsql security invoker set search_path = '' as $$
declare v_room public.game_rooms; v_state jsonb; v_round jsonb; v_turns jsonb; v_winner integer; v_artist jsonb; v_artists jsonb; v_player_count integer; v_expected integer;
begin
  select * into v_room from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  if not (v_room.state->'roomSeats') @> jsonb_build_array(p_client) then raise exception 'You are not seated in this room'; end if;
  v_state:=v_room.state; v_round:=v_state->'blindRound';
  v_player_count:=coalesce((v_state->>'playerCount')::integer,0);
  select count(*) into v_expected from generate_series(0,v_player_count-1) as seats(k) where jsonb_array_length(coalesce(v_state->'teams'->(seats.k),'[]'::jsonb)) < 12;
  if v_round is not null and v_state->'pending' is null and v_expected=0 then
    v_turns:=coalesce(v_round->'turns','[]'::jsonb);
    select (value #>> '{}')::integer into v_winner from jsonb_array_elements(v_turns) order by random() limit 1;
    v_artist:=v_round->'artist';
    if v_winner is not null then
      v_artist:=jsonb_set(jsonb_set(v_artist,'{origin}',to_jsonb(v_winner)),'{current}',to_jsonb(v_winner));
      v_state:=jsonb_set(v_state,array['teams',v_winner::text],coalesce(v_state->'teams'->v_winner,'[]'::jsonb)||jsonb_build_array(v_artist));
      select jsonb_agg(case when (artist->>'id')::integer=(v_artist->>'id')::integer then v_artist else artist end order by ordinal) into v_artists from jsonb_array_elements(v_state->'artists') with ordinality as roster(artist,ordinal);
      v_state:=jsonb_set(v_state,'{artists}',v_artists);
    end if;
    v_state:=jsonb_set(v_state,'{pending}',jsonb_build_object('artist',v_artist,'turns',v_turns,'winner',v_winner,'performance',v_round->'performance'));
    v_state:=jsonb_set(v_state,'{blindRound}','null'::jsonb);
    update public.game_rooms set state=v_state where code=p_room returning * into v_room;
  end if;
  return v_room;
end;
$$;

create or replace function public.advance_blind_audition(p_room text, p_client text)
returns public.game_rooms language plpgsql security invoker set search_path = '' as $$
declare v_room public.game_rooms; v_state jsonb; v_next integer; v_order jsonb;
begin
  select * into v_room from public.game_rooms where code=p_room for update;
  if not found then raise exception 'Room not found'; end if;
  if not (v_room.state->'roomSeats') @> jsonb_build_array(p_client) then raise exception 'You are not seated in this room'; end if;
  v_state:=v_room.state;
  if v_state->'pending' is null then raise exception 'This audition is not ready to advance'; end if;
  v_state:=jsonb_set(v_state,'{auditions}',coalesce(v_state->'auditions','[]'::jsonb)||jsonb_build_array(v_state->'pending'));
  v_state:=jsonb_set(v_state,'{pending}','null'::jsonb);
  v_next:=coalesce((v_state->>'auditionIndex')::integer,0)+1; v_order:=coalesce(v_state->'auditionOrder','[]'::jsonb);
  if v_next>=jsonb_array_length(v_order) then
    select coalesce(jsonb_agg(artist order by random()),'[]'::jsonb) into v_order from jsonb_array_elements(v_state->'artists') as artists(artist) where artists.artist->>'origin' is null;
    v_next:=0; v_state:=jsonb_set(v_state,'{auditionOrder}',v_order);
  end if;
  v_state:=jsonb_set(v_state,'{auditionIndex}',to_jsonb(v_next));
  update public.game_rooms set state=v_state where code=p_room returning * into v_room;
  return v_room;
end;
$$;

grant execute on function public.submit_blind_decision(text,text,boolean) to anon;
grant execute on function public.resolve_blind_round(text,text) to anon;
grant execute on function public.advance_blind_audition(text,text) to anon;
