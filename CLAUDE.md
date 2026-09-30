# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

"Proyecto Prion" — a live-action, geolocation-based zombie-vs-civilian game. Players run the SvelteKit
app on their phones while physically walking around a real playable zone; the backend detects proximity
between opposing roles via PostGIS and triggers timed combat encounters. All game logic (state machine,
combat resolution, narrative text) lives in Postgres; the frontend is essentially a thin polling client.

## Commands

- `npm run dev` — start the Vite/SvelteKit dev server
- `npm run build` / `npm run preview` — production build / preview it
- `npm run check` / `npm run check:watch` — svelte-kit sync + svelte-check (TypeScript/Svelte type checking)
- `npm run lint` — `prettier --check .`
- `npm run format` — `prettier --write .`

There is no test suite (no `test` script, no test files) — verify changes by running the app and, for
backend logic, by reasoning through the SQL or testing against the linked Supabase project.

Formatting: tabs, single quotes, no trailing commas, 100-char width (`.prettierrc`, via
`prettier-plugin-svelte`).

## Architecture

### Frontend (SvelteKit 5, runes mode forced — `svelte.config.js`)

- `src/routes/+page.svelte` — landing/auth-gate page
- `src/routes/login/+page.svelte` — email/password login via Supabase Auth
- `src/routes/game/+page.svelte` — the entire game screen and client-side game loop:
  - Watches geolocation (`navigator.geolocation.watchPosition`), draws a Leaflet map, checks whether
    the player is inside the playable zone polygon (point-in-polygon done client-side).
  - Every `SYNC_INTERVAL_MS` (10s), writes the player's position to `players.position` (WKT `POINT`)
    and invokes the `detect_encounter` edge function to check for a proximity match.
  - Polls (all via `setInterval`, no realtime subscriptions): `nearby_players` view (5s), the player's
    active encounter (3s), and the player's `events` log for the radio feed (5s).
  - Renders `CombatOverlay.svelte` (15s decision timer + result) during an active encounter,
    `RadioReceptora.svelte` (scrolling narrative log) always, and `FinalScreen.svelte` once a
    `game_end` event arrives (freezes all polling/geolocation at that point).
- `src/lib/sounds.ts` — synthesized Web Audio SFX (no audio files); must be unlocked on first pointer
  event per browser autoplay policy.
- `src/lib/supabase.ts` — the anon-key Supabase client used by all pages (`$env/static/public`).

### Backend (Supabase: Postgres + PostGIS + pg_cron + Edge Functions)

**`supabase/sql/prion_backend.sql` is the single source of truth for all backend SQL** (functions,
narrative data, grants). It documents/mirrors what is actually deployed on the linked Supabase project
(ref `uziyxukcasjmvcemtonp`) — running this file is *not* how deploys happen; changes are applied by
hand via the Supabase SQL editor (or CLI) and then this file is updated to match. It supersedes older
`prion_narrative.sql` / `prion_wire_narrative.sql` files, which are obsolete. Base tables (`players`,
`encounters`, `events`, `game_session`) predate this file and are only referenced, not created, here.

Core tables (schema for `players`/`encounters`/`events`/`game_session` lives in Supabase, not in repo):
- `players` — `role` (civil/zombie), `life`, `status` (active/radar_disabled/neutralized),
  `status_until`, `position` (geography), `current_encounter_id`.
- `encounters` — `civil_id`, `zombie_id`, `civil_decision`/`zombie_decision`, `result`, damages,
  `dice_roll`, timestamps, `*_timed_out` flags.
- `events` — per-player narrative log consumed by the frontend's "radio" feed
  (types: `encounter_start`, `encounter_result`, `conversion`, `neutralization`, `game_end`).
- `game_session` — one row per game run: `status` (setup/active/finished), `start_time`/`end_time`,
  `playable_zone` (PostGIS polygon), `winning_side`, `final_report` (jsonb snapshot).
- `narrative` — bank of flavor-text messages keyed by `(situation, role)`, picked randomly by
  `pick_narrative()`; `role = NULL` means a broadcast message (not role-specific).

Key SQL functions (all `SECURITY DEFINER`, `search_path` pinned to `public, extensions`):
- `handle_new_user()` — trigger on `auth.users` insert; randomly assigns civil/zombie and creates the
  `players` row.
- `get_playable_zone()` / `is_inside_zone()` — zone geometry and membership checks.
- `find_nearby_opponent()` — PostGIS `ST_DWithin` search (25m) for an eligible opposite-role player.
- `get_nearby_players()` (SECURITY DEFINER, returns only safe columns) wrapped by the
  `nearby_players` view (`security_invoker = true`) — this split exists specifically so the client can
  query a view without the RPC exposing the raw `players` table or PII.
- `create_encounter_transaction()` — locks both players, creates the `encounters` row, fires
  `encounter_start` events.
- `compute_and_resolve_encounter()` — the combat engine: resolves the decision pair into a result,
  applies damage, handles civil→zombie conversion and zombie neutralization, writes result + events.
  This is the one function actually called by both the manual flow and the timeout flow.
- `apply_timeouts()` — cron; force-defaults undecided players (civil→HUIR, zombie→MORDER) after 16s and
  resolves the encounter.
- `regenerate_civils()`, `restore_zombies()`, `restore_radar()` — periodic state healing crons.
- `close_game()` — cron; closes an expired `game_session`, computes `final_report`, fires `game_end`
  events to all players. Victory condition: civils win if ≥5 players still have `role = 'civil'`
  (a civil never sits at life ≤ 0 — hitting 0 converts them to zombie instead of "dying").
- `get_final_report()` — per-player view combining the frozen global report with individual stats.
- `assign_roles_balanced()` — one-off manual reshuffle run before opening a game; only touches players
  whose `nick LIKE 'tester%'` and requires an exact headcount match, or it aborts.
- Cooldown after combat is density-scaled, not fixed: `compute_and_resolve_encounter()` computes
  `v_density_scale := LEAST(1.0, v_player_count::NUMERIC / 20)` (player count = `tester%` accounts) and
  applies `GREATEST(45, ROUND(180 * v_density_scale))` as the base cooldown, `GREATEST(75, ROUND(300 *
  v_density_scale))` for the civil's clean-escape bonus (zombies always get the base duration, never the
  bonus — only the civil that escapes a `HUIR` vs `MORDER` result gets it). The `/20` divisor is only
  valid because the MVP zone is fixed size; it must become players/area, not players/20, before zone
  size or count varies — known debt, not yet fixed.
- All functions that can end/reshuffle the game (`assign_roles_balanced`, `close_game`) — plus the
  orphaned `resolve_encounter_transaction` RPC (see Edge Functions below) — have EXECUTE revoked
  **`FROM PUBLIC`**, not just `FROM anon, authenticated`. This distinction matters: a bare `REVOKE ...
  FROM anon, authenticated` does *not* actually block those roles, because Postgres grants EXECUTE to
  `PUBLIC` by default on every new function and `anon`/`authenticated` inherit it through their implicit
  membership in `PUBLIC` regardless of an individual revoke. This was a real, live vulnerability
  (found and fixed 29/09/2026) — anyone with the public anon key could call `close_game()` or
  `assign_roles_balanced()`. Only `service_role` (crons, edge functions) or the Supabase SQL editor can
  call these now. When adding a new sensitive function, revoke `FROM PUBLIC` explicitly, and verify with
  `has_function_privilege('anon', oid, 'EXECUTE')`, not just by reading the `REVOKE` statement.
  `apply_timeouts`/`regenerate_civils`/`restore_zombies`/`restore_radar`/`rls_auto_enable` are still
  publicly executable (same class of issue, lower severity, not yet a closed decision either way).

pg_cron schedule is not stored in the repo (config lives in Supabase); the comment block at the bottom
of `prion_backend.sql` documents what's active: `apply_timeouts` (5s), `restore_zombies`/`restore_radar`
(30s), `regenerate_civils` (hourly), `close_game` (30s).

### Edge Functions (`supabase/functions/*/index.ts`, Deno)

Each function creates two Supabase clients: an anon-key client scoped to the caller's JWT (to identify
`auth.getUser()`) and a service-role admin client (to bypass RLS for the actual game-state writes).

- `detect_encounter` — called by the client every position sync; validates an active game session, the
  player's status/position freshness/zone membership, finds a nearby opponent, and calls
  `create_encounter_transaction`.
- `submit_decision` — called when a player picks a combat action; validates the decision is legal for
  their role in this encounter, stores it, and once both sides have decided, calls
  `compute_and_resolve_encounter` directly.

The `resolve_encounter` edge function (a separate, duplicate combat-resolution implementation calling an
RPC `resolve_encounter_transaction`) was confirmed dead and deleted 29/09/2026, along with its
`[functions.resolve_encounter]` block in `supabase/config.toml`. The `resolve_encounter_transaction` SQL
function itself is still orphaned in the live database (not defined in `prion_backend.sql`, not called by
anything) — it was not dropped, only stripped of its public EXECUTE grant (see grants note above).

### Local Supabase config

`supabase/config.toml` is mostly CLI defaults; the parts that matter are the four `[functions.*]`
blocks (all `verify_jwt = false` — auth is checked manually inside each function via the JWT-scoped
client) and `major_version = 17` for local Postgres.

## Project discipline & closed decisions

- **MVP closed and validated 21/09/2026.** It shipped without the originally planned 20-player test —
  the real bar (do people want to replay?) was already met by the 07/08/2026 field test. This is not a
  lowered bar, it's a closed decision. Do not reopen it or propose the 20-player test as outstanding work.
- **Server is the single source of truth.** Combat and game logic live in Postgres (compute_and_resolve_encounter). This is a closed architectural decision — do not suggest moving logic to the client or edge functions.
- **Combat logic is closed.** The six combat branches and the dice mechanic are validated and final. Do not redesign them without an explicit request.
- **v2 is now in progress (started 29–30/09/2026).** The items below, "parked for v1," are the actual
  starting material for v2 — they are no longer things to leave alone, they're the backlog. Current
  design status (what's decided vs. still open) lives in the project doc
  (`claude/prion-estado-actual.md` in the Prion project on claude.ai), not in this file — this file only
  gets updated once a v2 change actually lands in code/schema, same as it always has for v1. Do not
  assume anything about v2 mechanics is implemented without checking the actual code/schema first.
- **Parked for v1, now v2 starting material (NOT bugs):** zombie progression (brain-eating → power), sonar-sweep radar visual, narrative tension during the resolution wait, polling→realtime migration, Sims-style solo mode (daily character care, training), geolocated equipment and missions. The zone concept itself (currently a fixed ~6ha polygon) is also on the table for removal in v2 ("zona = mundo" — playable anywhere, no polygon) but this is explicitly paused, not decided: v2 volunteer testing may want the zone kept as a test condition, so don't remove or rework zone code without confirming current status in the project doc first.
- When unsure whether something is a bug or a deliberate choice, ask before changing it.
