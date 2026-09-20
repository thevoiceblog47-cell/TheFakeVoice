create table if not exists public.game_decisions (
  room text not null,
  round_id integer not null,
  seat integer not null check (seat between 0 and 3),
  decision boolean not null,
  created_at timestamptz not null default now(),
  primary key (room, round_id, seat)
);

alter table public.game_decisions enable row level security;

drop policy if exists "blind decisions can be read" on public.game_decisions;
create policy "blind decisions can be read"
on public.game_decisions for select to anon using (true);

drop policy if exists "blind decisions can be recorded" on public.game_decisions;
create policy "blind decisions can be recorded"
on public.game_decisions for insert to anon with check (true);
