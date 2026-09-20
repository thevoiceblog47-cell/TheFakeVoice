# Turn

A private, Voice-inspired coach simulator with local and Supabase-backed multiplayer rooms.

## Publish with GitHub Pages

1. Create a new **public** GitHub repository.
2. Upload every project file, including `ContestantsList.xlsx`, or push this folder with Git.
3. In GitHub, open **Settings → Pages** and set **Source** to **GitHub Actions**.
4. Push to `main`. The included workflow publishes the site automatically.
5. Open the **Actions** tab, wait for **Deploy to GitHub Pages** to complete, then use the site link shown by GitHub.

The live game reads `ContestantsList.xlsx` whenever a new season begins. Update that spreadsheet, commit/push it, and GitHub Pages will deploy the updated roster.

## Multiplayer setup

The game uses Supabase for private rooms, locked Blind Audition choices, and chat. Run the SQL in `MULTIPLAYER_SETUP.md`, `SUPABASE_BLIND_FIX.sql`, and `SUPABASE_LOBBY_SYNC.sql` once in your Supabase SQL Editor before using multiplayer.

GitHub Pages is static hosting. No Netlify functions or build command are required.

## Project structure

- `index.html` contains the game interface and season gameplay.
- `scripts/config.js` contains the browser-safe Supabase project configuration.
- `scripts/multiplayer-lobby.js` owns lobby readiness, host start, and the guest transition into a started room.

The Supabase anon key is intentionally public for this static browser app; access is limited by the row-level-security policies in the setup SQL.
