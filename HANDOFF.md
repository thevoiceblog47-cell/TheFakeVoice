# The Voice Simulator — Project Handoff

## Project at a glance

This is a browser-based, Voice-inspired simulator. The current app is deliberately a static site: the full UI and game logic live in `index.html`; contestant data originates in `ContestantsList.xlsx`; private online rooms use Supabase; GitHub Pages is configured for hosting.

Primary files:

- `index.html` — the entire application: markup, styling, game engine, local play, multiplayer, and Supabase integration.
- `ContestantsList.xlsx` — contestant roster. The app reads names, genres, and image URLs from this workbook at runtime using SheetJS.
- `MULTIPLAYER_SETUP.md` — Supabase setup and deployment notes.
- `SUPABASE_BLIND_FIX.sql` — required database migration for authoritative Blind Audition decisions.
- `.github/workflows/deploy-pages.yml` — GitHub Pages deployment workflow.
- `README.md` — concise GitHub Pages publishing instructions.

## What has been built

### Core season structure

- Startup/menu flow with coach customization.
- Supports 0–4 local players. Zero-player mode is spectator mode, but still gives the viewer controls to advance reveals.
- Blind Auditions with 12-person teams, CPU coaches, turns, contestant choice, shuffled artists, re-auditions for artists who receive no turns, and a cap that advances only when every team is full.
- Battles: player pairings, CPU pairings with genre preference, winners/losers, steals, and appropriately interspersed coach battles.
- Knockouts with their own pairing and steal rules.
- Live Playoffs: performance and result shows by team; two Public Vote advances and one coach save per team.
- Live shows: Top 12 → 10 → 8 → 6 → 5 → 4 → Finale, performance/result formats, bottom groups, eliminations, and final placements.

### Strategic simulation layer

- Performance scores, qualitative judge comments, fan tweets, momentum, fanbase, and public voting logic.
- Vote weighting is intended to favor fanbase most heavily, with performance and RNG still mattering.
- Spotify-stream charts begin at the Live Playoffs and are deliberately a noisy indicator rather than the vote itself.
- Streaming, judge comments, and tweets are intentionally omitted from the formal season tracker.

### UI and trackers

- Black/red visual direction.
- Contestant images appear in active game views, pairings, performance shows, results, and a visual contestant tracker. They are not used in the Wikipedia-style team/season tables.
- Portrait crops are configured to favor the top of the supplied 1024×1536 images.
- Teams chart imitates The Voice Wikipedia team-table layout, including stage-based colors, stolen contestants, strike-through treatments, and elimination placement ordering.
- Season tracker has Blind Auditions, Battles, Knockouts, Playoffs, and Live Shows. The live-results summary chart updates over the season.
- Spotify chart tab puts the newest week first.

### Multiplayer

- Uses browser-local `clientId` values to identify players.
- Private rooms are created/joined through a six-character room code in the URL.
- A lobby lets each participant rename their own coach, ready up, and wait for the host to begin.
- Player count is derived from actual participants; unclaimed coach seats become CPUs.
- Multiplayer Blind Audition decisions are persisted separately through Supabase `game_decisions`, preventing a turn/pass click from being lost or submitted twice.
- Multiplayer chat is a sidebar which pushes the game UI over instead of overlapping it.
- Each human player controls their own chair turns, pairings, battle/knockout decisions, steals, and Playoff saves on their own screen.

## Supabase details

The app already has the project URL and public anon key configured in `index.html`. Never add a Supabase service-role key to this static site.

Supabase tables used:

- `game_rooms` — the serialized season/room state.
- `game_messages` — room chat messages.
- `game_decisions` — authoritative Blind Audition turn/pass records.

`SUPABASE_BLIND_FIX.sql` must have been run in the Supabase SQL editor for the Blind Audition database lock to work. If a new Supabase project is used, repeat all setup/migration instructions in `MULTIPLAYER_SETUP.md` and run this SQL migration.

## Most recent fixes (September 20, 2026)

The latest request reported two multiplayer blockers:

1. Guests remained on the lobby after the host clicked **Start Blind Auditions**.
2. Battles/Knockouts could display a waiting state for a CPU coach to decide whether to steal.

The end of `index.html` now contains compatibility overrides that address those bugs:

- Lobby state is continuously checked while a guest is waiting.
- Delayed generic click saves are suppressed during lobby state, so a guest’s stale lobby snapshot cannot overwrite the host’s newer `roomStarted: true` snapshot.
- Host start remains explicit and confirms the saved room state.
- CPU-only steal situations resolve immediately; waiting states are shown only for a human player’s decision.
- Battle/Knockout resolution and next-battle/next-knockout transitions explicitly save the updated shared room state.

Verification completed after this change:

```bash
git diff --check
sed -n '/<script>/,/<\/script>/p' index.html | sed '1d;$d' | /System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc --dumpException
```

The JavaScriptCore check naturally reports that `document` is unavailable because it is a browser DOM check; no JavaScript syntax error was reported.

## Important implementation caution

`index.html` evolved iteratively and contains multiple late-script function overrides (for example `hydrateRoom`, `resolveBattle`, `beginSharedSteal`, `renderStableLobby`, and `pollRoom`). The final declarations near the end of the file are the active ones.

When fixing multiplayer behavior, avoid broad refactors unless the code is first consolidated carefully. Safest pattern:

1. Locate every definition using `rg -n "functionName|function functionName" index.html`.
2. Confirm the final definition/override that runs at browser load.
3. Make a small, end-of-script override or modify the final implementation.
4. Test with two separate browsers/incognito profiles and a fresh room code.

## Recommended next test plan

After publishing the current `index.html` to GitHub Pages:

1. Open the game in two isolated browser sessions (normal + incognito is fine).
2. Create a new room from browser A and open the invite link in browser B.
3. Rename both coaches, save names, ready both, and host-start the room.
4. Confirm browser B enters Blind Auditions within about one second.
5. Complete a few Blind Auditions; verify each click persists exactly once and assignment does not change after reveal.
6. Reach a Battle where the losing artist can only be stolen by CPUs. It should immediately resolve and show **Next Battle**, never a CPU waiting panel.
7. Test a Battle where a human is eligible to steal; only that human should receive the steal/pass controls.
8. Repeat the same cases for Knockouts, then test Playoff saves and one Live Show result sequence.

Use fresh rooms for validation because older serialized room state may predate these changes.

## Publishing through GitHub Pages

The repository includes a GitHub Actions Pages workflow. Commit and push the project files to GitHub, then in the repository:

1. Open **Settings → Pages**.
2. Under **Build and deployment**, choose **GitHub Actions**.
3. Pushes to the configured branch trigger the Pages deployment.
4. The deployed URL appears in the completed **Actions** workflow and on the Pages settings page.

Because multiplayer calls Supabase directly from the browser, GitHub Pages is sufficient for this project and has no server hosting cost.

## Useful commands

```bash
# Find active/repeated implementations before editing multiplayer logic
rg -n "hydrateRoom|pollRoom|beginSharedSteal|resolveBattle|renderStableLobby" index.html

# Basic whitespace/conflict check
git diff --check

# JavaScript parsing check (the final 'document' error is expected outside a browser)
sed -n '/<script>/,/<\/script>/p' index.html | sed '1d;$d' | /System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc --dumpException
```

## Product direction to retain

The user wants this to feel sleek, dramatic, visual, and a little campy—not like a spreadsheet simulator. Wikipedia-like tables are intentionally used for trackers, but active gameplay should remain image-forward, fast to click through, and visually clear. The multiplayer goal is private rooms where friends each control a different coach in the same shared season.
