# 03 — Architecture

## Overview

```
React (Vite)  ──REST /api/*──────────►  Spring Boot  ──owner DataSource──►  Postgres: app.*, football.* (DDL, seed)
     ▲                                   │   │
     └──STOMP /ws  (server→client events)┘   └──sandbox DataSource (read-only role)──► Postgres: football.* (SELECT only)
```

- **Commands** (create match, submit guess, forfeit) go over REST. **Events** (guess
  evaluated, match finished) are pushed over STOMP. Practice mode needs no WebSocket at all.
- Postgres is the source of truth for match state. Per-match group/pool sets are also
  cached in memory (immutable once a match starts) to make scoring cheap. They're rebuilt
  from the DB on a cache miss, e.g. after a restart.

## Backend packages (`com.hiddenxi`)

| Package | Responsibility |
|---|---|
| `seed` | Seeder runner (profile `seed`), see data spec |
| `catalog` | Static description of the `football` schema (tables, columns, types, comments) loaded from `information_schema` at startup. Used by the validator (column→table resolution) and served to the frontend for the schema browser and autocomplete |
| `sandbox` | `QueryValidator` (JSqlParser + allowlists), `QueryRewriter` (wrapper), `SandboxExecutor` (JdbcTemplate on the sandbox DataSource), `PredicateColumnExtractor` (which `players` columns appear in filtering clauses). See `04-sandbox-security.md` |
| `game` | Pure domain, no Spring: `Prompt`, `PromptLibrary`, `PoolBuilder`, `Scorer`, `RevealEngine`, `GameRules` (tunable constants). Deterministic given a `Random` and a `Clock` |
| `match` | `MatchService` (orchestration and transactions), JPA entities/repositories for `app.*`, `MatchTimerScheduler` |
| `realtime` | STOMP config, `MatchEventPublisher` (wraps `SimpMessagingTemplate`), session/presence tracking for disconnect forfeits |
| `api` | REST controllers, request/response records, error mapping (`@RestControllerAdvice`) |
| `account` | Guest sessions (Phase 5), real accounts (Phase 6) |

## Database layout

- Schema `football`: game data (see data spec). Owned by the owner role; `SELECT`
  granted to `hiddenxi_sandbox`.
- Schema `app`: application data. Owned by the owner role; **no** grants to the sandbox role.

Roles (created in a Docker init script, since some settings need a superuser; passwords
from env vars):

| Role | Used by | Privileges |
|---|---|---|
| `hiddenxi_owner` | Flyway, JPA, seeder | Owns both schemas |
| `hiddenxi_sandbox` | `SandboxExecutor` only | `CONNECT`, `USAGE` on `football`, `SELECT` on its tables. Role defaults: read-only transactions, `statement_timeout`, `search_path=football`, `work_mem`, `temp_file_limit`, connection limit |

Two `DataSource` beans: the primary (owner, used by JPA/Flyway) and `@Qualifier("sandbox")`
(a small Hikari pool, max 8, `readOnly=true`). Configure the second explicitly; Spring
Boot only auto-configures one.

### `app` tables (Flyway `V2__app_schema.sql`)

```sql
CREATE SCHEMA app;

CREATE TABLE app.users (
  id         uuid PRIMARY KEY,
  nickname   text NOT NULL,
  is_guest   boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app.matches (
  id              uuid PRIMARY KEY,
  mode            text NOT NULL CHECK (mode IN ('PRACTICE','DUEL')),
  status          text NOT NULL CHECK (status IN ('WAITING','IN_PROGRESS','FINISHED','ABANDONED')),
  invite_code     text UNIQUE,                 -- DUEL only
  seed            bigint NOT NULL,             -- RNG seed used for pool/slots (reproducibility)
  created_at      timestamptz NOT NULL DEFAULT now(),
  started_at      timestamptz,
  ends_at         timestamptz,
  finished_at     timestamptz,
  winner_user_id  uuid REFERENCES app.users,
  finish_reason   text CHECK (finish_reason IN ('EXACT_MATCH','TIMEOUT','BUDGET','FORFEIT','DRAW')),
  version         bigint NOT NULL DEFAULT 0
);

CREATE TABLE app.match_participants (
  match_id      uuid REFERENCES app.matches,
  seat          smallint CHECK (seat IN (1,2)),
  user_id       uuid NOT NULL REFERENCES app.users,
  prompt_id     text NOT NULL,                 -- the prompt defining THIS seat's own group
  guesses_used  int NOT NULL DEFAULT 0,
  best_jaccard  numeric(5,4) NOT NULL DEFAULT 0,
  PRIMARY KEY (match_id, seat)
);

CREATE TABLE app.match_pool (
  match_id  uuid REFERENCES app.matches,
  player_id integer NOT NULL,
  PRIMARY KEY (match_id, player_id)
);

CREATE TABLE app.match_group_members (
  match_id   uuid REFERENCES app.matches,
  owner_seat smallint NOT NULL,                -- whose group
  slot_no    smallint NOT NULL,                -- 1..N, opaque to the guesser
  player_id  integer NOT NULL,
  PRIMARY KEY (match_id, owner_seat, slot_no),
  UNIQUE (match_id, owner_seat, player_id)
);

CREATE TABLE app.guesses (
  id               uuid PRIMARY KEY,
  match_id         uuid NOT NULL REFERENCES app.matches,
  seat             smallint NOT NULL,          -- who guessed (targets the other seat's group; PRACTICE targets seat 1's prompt)
  seq_no           int NOT NULL,               -- per seat, counts consumed guesses
  sql_text         text NOT NULL,
  status           text NOT NULL CHECK (status IN ('SCORED','TIMEOUT','LATE')),
  returned_count   int, hit_count int, false_positive_count int, missed_count int,
  jaccard          numeric(5,4),
  is_exact         boolean NOT NULL DEFAULT false,
  reveals          jsonb NOT NULL DEFAULT '[]', -- [{slot, columns:{col:value}}]
  exec_ms          int,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (match_id, seat, seq_no)
);
```

Rejected and errored guesses are not stored as guesses (they don't consume budget). Log
them at INFO with match id and seat.

In Practice mode there is one participant (seat 1) whose `prompt_id` defines the target
group, which the same participant guesses. Keep the code path the same as Duel by
treating "target seat" as a function: `target(seat) = mode == PRACTICE ? 1 : 3 - seat`.

## Guess pipeline (the core)

```
POST /api/matches/{id}/guesses {sql}
 1. Authorize: caller is a participant; match IN_PROGRESS; now < ends_at; guesses left;
    no guess in flight for this seat; min interval respected     → 409/429 otherwise
 2. Validate (QueryValidator)                                    → 400 {code, message}, no budget used
 3. Rewrite  (QueryRewriter): SELECT DISTINCT q.player_id FROM (<sql>) AS q LIMIT 5001
 4. Execute  (SandboxExecutor) → Set<Integer> universeResult    → timeout: budget used, status TIMEOUT
 5. Score    (Scorer): R = result ∩ pool; hits, fp, missed, jaccard; exact = (R == G)
 6. Reveal   (RevealEngine): for each hit → slot, plus values of players columns from
    PredicateColumnExtractor (fetched via the owner DataSource from football.players,
    never via the sandbox)
 7. Persist in one transaction (owner DataSource):
      insert guess (seq_no = guesses_used + 1), update participant guesses_used/best_jaccard
      if exact: UPDATE app.matches SET status='FINISHED', winner_user_id=?, finish_reason='EXACT_MATCH',
                finished_at=now(), version=version+1
                WHERE id=? AND status='IN_PROGRESS'
         → 1 row: this guess wins.  0 rows: the match already ended → mark guess LATE.
 8. After commit: publish GuessEvaluated (and MatchFinished if won). Return the result.
```

Steps 3–6 run outside any DB transaction on the owner DataSource. Only step 7 is
transactional. Concurrency guarantees:

- **Single winner:** the conditional `UPDATE ... WHERE status='IN_PROGRESS'` is an atomic
  compare-and-set in Postgres. Two simultaneous exact guesses can't both win, even across
  multiple app instances.
- **Per-seat ordering:** `UNIQUE (match_id, seat, seq_no)` plus the in-flight check. A
  per-seat in-memory lock is fine for a single instance; the unique constraint is the
  backstop.
- **Budget:** step 7 re-checks `guesses_used < guessBudget` inside the transaction
  (`SELECT ... FOR UPDATE` on the participant row).

## Pool builder (pure function)

```
input: prompts (1 or 2), universe ids, promptMatches(prompt) → Set<Integer>, rules, Random
for each prompt p: M_p = promptMatches(p) ∩ universe; S_p = sample(M_p, min(membersPerPrompt, |M_p|))
base   = ∪ S_p
decoys = sample(universe − ∪ M_p, poolSize − |base|)
pool   = base ∪ decoys
group_p = pool ∩ M_p                       # may exceed S_p via natural overlap
reject if any |group_p| ∉ [groupSizeMin, groupSizeMax] or jaccard(group_1, group_2) > maxGroupJaccard
slots: shuffle(group_p) → 1..N
```

`promptMatches` runs the prompt's canonical SQL once per prompt through the sandbox
executor and caches the result for the app's lifetime (the data is frozen). Retry with
new prompts up to 20 times, then fail loudly (that's a prompt library bug).

## Scoring and reveal details

- `RevealEngine` input: guess number, hit player ids, slot map, extracted `players`
  columns, and the players' rows (from an in-memory `Map<Integer, PlayerRow>` of the
  universe loaded at startup, 2,837 rows). Output: `[{slot, columns: {name: value}}]`.
- `current_club_id` is revealed as `current_club: <club name>`.
- Values are formatted for display server-side (dates ISO, money as integers, NULL → `"unknown"`).
- The client merges reveals into its board state. The server also returns the full board
  state in `GET /api/matches/{id}` for reconnects.

## Timer and end of match

- `MatchTimerScheduler` (`@Scheduled(fixedDelay = 1000)`) finds `IN_PROGRESS` matches past
  `ends_at` and finishes them with the same compare-and-set `UPDATE` (reason `TIMEOUT`,
  or `DRAW` on equal best Jaccard), then publishes `MatchFinished`.
- Budget exhaustion: after each guess, if both seats are out of guesses, finish
  immediately using the same logic.
- Clients render the countdown from `endsAt`; the server is authoritative.

## REST API (v1)

| Method & path | Body → Response | Notes |
|---|---|---|
| `GET /api/schema` | → tables, columns, types, descriptions | From `catalog` |
| `POST /api/session` | `{nickname}` → `{userId, nickname}` | Guest session (cookie). Phase 5 |
| `POST /api/practice` | → `MatchView` | Creates and starts a Practice match |
| `POST /api/duels` | → `{matchId, inviteCode}` | Status WAITING |
| `POST /api/duels/join` | `{inviteCode}` → `MatchView` | Starts the match; publishes `MatchStarted` |
| `GET /api/matches/{id}` | → `MatchView` | Full snapshot for the caller (own group included, hidden data excluded) |
| `POST /api/matches/{id}/guesses` | `{sql}` → `GuessResult` | The pipeline above |
| `POST /api/matches/{id}/forfeit` | → `MatchView` | |

Error body: `{code, message, details?}` with codes such as `VALIDATION_FAILED`,
`SQL_ERROR`, `RATE_LIMITED`, `NO_GUESSES_LEFT`, `MATCH_NOT_ACTIVE`, `NOT_A_PARTICIPANT`.

`MatchView` (caller-specific): `id, mode, status, endsAt, guessBudget, you {seat,
guessesUsed, bestJaccard, ownPrompt, ownGroup[]}, opponent {nickname, guessesUsed,
bestJaccard}?, targetGroupSize, boards {mine: Board, opponentsViewOfMine: Board?},
guesses[]`, and at FINISHED also `result {winner, reason, prompts, groups}`.

## STOMP events

Endpoint `/ws`. Clients subscribe to `/topic/matches/{id}` (authorization checked in a
`ChannelInterceptor`: only participants may subscribe). All events carry `type`,
`matchId`, `at`.

| Event | Payload |
|---|---|
| `MatchStarted` | `endsAt`, seats/nicknames, both group sizes |
| `GuessEvaluated` | `seat, seqNo, sql, status, returned, hits, falsePositives, missed, jaccard, reveals[], guessesUsed, bestJaccard` |
| `PresenceChanged` | `seat, connected` |
| `MatchFinished` | `winnerSeat?, reason, prompts, groups (full identities)` |

`GuessEvaluated` is safe to broadcast to both players. Its reveals concern the target
group, which belongs to the other player. See the visibility table in the product spec.

## Frontend structure

```
src/
  api/            fetch wrappers + TanStack Query hooks (useSchema, useMatch, useSubmitGuess…)
  realtime/       STOMP client, subscribe hook → dispatches events into the match store
  store/          Zustand matchStore: boards, guess log, counters (event-sourced from REST snapshot + WS events)
  features/
    editor/       CodeMirror 6 SQL editor, locked first line "SELECT player_id", schema autocomplete
    board/        Board grid (slots × revealed columns + match chips)
    guesses/      Guess log with stats; click to load SQL into the editor
    schema/       Schema browser panel + coverage notice
    match/        GamePage (Practice/Duel), Lobby (create/join), Summary
  components/     shared UI
```

Board rendering: rows = slots 1..N; columns = the union of revealed column names, in a
fixed order (name, position, sub_position, foot, height, citizenship, birth country/city,
birth date, current club, values, agent, caps/goals, contract). Found slots are highlighted.
Unrevealed cells are blank.

Visual direction: a dark, stadium-at-night scoreboard aesthetic (deep green/charcoal, one
bright accent, monospace for SQL and numbers). Keep it readable first.

## Caching

None in v1. Keep `SandboxExecutor` behind an interface. If metrics later show repeated
identical normalized queries with meaningful latency, add a Caffeine cache keyed by the
normalized SQL hash. The data is frozen, so the cache never needs invalidating.

## Observability

Actuator health/info/metrics. Timers for sandbox execution latency, counters for
validation rejections by code, and timeouts. Log every executed sandbox query at DEBUG
with match id, seat, duration, and row count.

## Testing strategy

- **Domain unit tests:** PoolBuilder (seeded Random, size/overlap rules), Scorer, RevealEngine.
- **Sandbox:** validator unit tests driven by the security corpus (accept and reject lists),
  and integration tests against Testcontainers Postgres with the real seed.
- **Prompt library:** an integration test runs every prompt and asserts size bounds
  (see `05-prompt-library.md`).
- **Concurrency:** two threads submit exact-match guesses for the same match at the same
  instant (use a `CountDownLatch`). Assert exactly one winner and one `LATE` guess.
  Repeat 50×.
- **API:** MockMvc slice tests for error mapping and authorization.
- **Frontend:** store reducers (event application), board rendering, editor prefix lock.
