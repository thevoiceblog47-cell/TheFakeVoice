# Supabase setup for TURN

The app already has its Supabase project URL and public anon key in
[`index.html`](./index.html). It stores a shared game in `game_rooms` and its
chat in `game_messages`.

1. Open your Supabase project dashboard.
2. Go to **SQL Editor** → **New query**.
3. Paste in the complete contents of [`supabase/schema.sql`](./supabase/schema.sql),
   then choose **Run**.
4. Publish `index.html`, `contestants.json`, and `contestantslist.xlsx` together.
5. Open the site, select **PLAY WITH FRIENDS**, create a room, and copy the invite link.

The browser uses the public anon key, which is normal for a client app. The
included row-level-security policies allow anyone with a room code to access
the shared game, so do not store personal or confidential information in room
state or chat. A sign-in or server-side room token system would be the next
step if you want private or moderated rooms.
