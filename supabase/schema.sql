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
