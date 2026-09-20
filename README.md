# Turn

A private, Voice-inspired coach simulator rebuilt around atomic multiplayer actions.

## Publish with GitHub Pages

1. Create a new **public** GitHub repository.
2. Upload every project file, including `ContestantsList.xlsx`, or push this folder with Git.
3. In GitHub, open **Settings → Pages** and set **Source** to **GitHub Actions**.
4. Push to `main`. The included workflow publishes the site automatically.
5. Open the **Actions** tab, wait for **Deploy to GitHub Pages** to complete, then use the site link shown by GitHub.

The live game reads `ContestantsList.xlsx` whenever a new season begins. Update that spreadsheet, commit/push it, and GitHub Pages will deploy the updated roster.

## Multiplayer setup

Run `SUPABASE_LOBBY_SYNC.sql` once in your Supabase SQL Editor before using multiplayer. It is the rebuilt database setup; prior snapshot-sync migrations are no longer used.

GitHub Pages is static hosting. No Netlify functions or build command are required.

## Project structure

- `index.html` contains the rebuilt lobby and synchronized game client.
- `scripts/config.js` contains the browser-safe Supabase project configuration.
- `SUPABASE_LOBBY_SYNC.sql` contains the transactional room, membership, and action-log API.

The Supabase anon key is intentionally public for this static browser app; access is limited by the row-level-security policies in the setup SQL.
