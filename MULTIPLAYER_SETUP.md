# Multiplayer setup

The rebuilt game uses one Supabase migration and no browser-side room snapshots.

1. Create a Supabase project and open **SQL Editor**.
2. Run all of `SUPABASE_LOBBY_SYNC.sql`.
3. In **Project Settings → API**, copy the Project URL and anon public key into `scripts/config.js`.
4. Deploy the folder as a static site, then create a room and share its link.

The database accepts lobby changes and gameplay choices only through transactional functions. Each coach decision uses an immutable action slot, so a second browser cannot overwrite a decision or erase another player’s update. The host can advance an audition only after every connected coach has submitted a choice.

Run this migration for a fresh room database; the earlier `SUPABASE_BLIND_FIX.sql` migration is obsolete for the rebuilt client.
