# Private multiplayer setup

This is designed for a small, private game night: one shared season, with every browser seeing the latest saved state. The game writes to a Supabase table and checks for updates every 2.5 seconds.

## 1. Create the free database

1. Create a free project at [Supabase](https://supabase.com/).
2. In **SQL Editor**, run this exact SQL:

```sql
create table public.game_rooms (
  code text primary key,
  state jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.game_rooms enable row level security;

create policy "private game rooms can be read"
on public.game_rooms for select to anon using (true);

create policy "private game rooms can be created or updated"
on public.game_rooms for insert to anon with check (true);

create policy "private game rooms can be updated"
on public.game_rooms for update to anon using (true) with check (true);

create table public.game_messages (
  id bigint generated always as identity primary key,
  room text not null,
  author text not null,
  body text not null check (char_length(body) <= 280),
  created_at timestamptz not null default now()
);

alter table public.game_messages enable row level security;

create policy "room chat can be read"
on public.game_messages for select to anon using (true);

create policy "room chat can be sent"
on public.game_messages for insert to anon with check (true);

create table public.game_decisions (
  room text not null,
  round_id integer not null,
  seat integer not null check (seat between 0 and 3),
  decision boolean not null,
  created_at timestamptz not null default now(),
  primary key (room, round_id, seat)
);

alter table public.game_decisions enable row level security;

create policy "blind decisions can be read"
on public.game_decisions for select to anon using (true);

create policy "blind decisions can be recorded"
on public.game_decisions for insert to anon with check (true);
```

3. Also run the contents of `SUPABASE_BLIND_FIX.sql` and `SUPABASE_LOBBY_SYNC.sql`. The latter is required so simultaneous lobby updates do not overwrite each other.
4. In **Project Settings → API**, copy the **Project URL** and the **anon public** key. Do not use the `service_role` key.
5. In `scripts/config.js`, replace the two values:

```js
supabaseUrl: 'https://your-project.supabase.co',
supabaseAnonKey: 'your-anon-public-key'
```

The anon key is intentionally safe to ship in a browser app. The table stores only game state. Treat room links like an invite: anyone with one can open and advance that room.

## 2. Put it on Netlify

1. Create a free Netlify account.
2. Drag the entire `The Voice` folder into Netlify Drop, or connect the folder to a Git repository and deploy it as a static site.
3. There is no build command: `index.html` is the publish entry point.
4. Open the assigned `https://…netlify.app` address.

## Updating contestants

`ContestantsList.xlsx` is the live roster source. The game reads the worksheet named **Contestants** each time a new season starts. Keep these column headers exactly as written:

`Contestant`, `Genre`, `Image Link`, `Age`, `Hometown`, and optionally `Gender`.

To update the game, edit that workbook, save it with the same filename in the project folder, and redeploy to Netlify. No JavaScript roster edits are needed. The game uses supplied age and hometown values when present, and fills either with a random value when blank.

## 3. Start a room

1. Choose **Private Multiplayer** on the opening menu.
2. Leave the room-code prompt blank, set the player count/coaches, and start the season. A six-character room is created.
3. Use **Copy link** in the top bar and send it to your friend.
4. Your friend opens that link, chooses an available coach seat, and the game assigns that browser to the selected team.

Each player sees only the decisions for their own coach: chair turns, their team’s matchups and winner choices, steals, and Live Playoff save. Everyone sees the same shared performance and results screens. Avoid both trying to advance a shared passive reveal at the exact same instant.

Online rooms now open in a lobby. Each friend enters a coach name and clicks **I’m ready**; the host can begin only when every signed-in coach is ready. The player count is determined automatically by the lobby. The room chat button appears after the host starts the season.
