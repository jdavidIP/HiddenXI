# 06 — Implementation Plan

Work top to bottom. Each phase ends in something runnable and tested. Check boxes off as
you go (`[x]`). Don't start a phase until the previous phase's definition of done is met.

---

## Phase 0 — Scaffold

- [x] Monorepo layout as in `CLAUDE.md`; `.gitignore` (ignore `data/raw/`, `data/work.duckdb`, build outputs; **commit** `data/seed/*.csv.gz`)
- [x] `docker-compose.yml`: `postgres:18` with a named volume, healthcheck, init script dir
      (`infra/db/init/`) that creates the `hiddenxi` database and the owner and sandbox roles
      (see `04-sandbox-security.md` §4), passwords from `.env` (commit `.env.example` only)
- [x] Backend: Spring Boot 4.x project (Java 25, Maven wrapper, package `com.hiddenxi`),
      dependencies listed in `CLAUDE.md`; Actuator health; `application.yml` with the
      `hiddenxi.game.*` defaults from the product spec, bound to a `@ConfigurationProperties` record
- [x] Frontend: Vite + React + TS (strict), ESLint, Vitest, Tailwind; dev proxy for `/api` and `/ws` to `:8080`
- [x] GitHub Actions: backend `./mvnw verify` (Testcontainers works on GitHub runners); frontend lint, typecheck, test
- [x] README stub: what it is, how to run

**Done when:** `docker compose up -d db` + `./mvnw spring-boot:run` → `/actuator/health` is UP;
`npm run dev` serves a placeholder page; CI is green.

---

## Phase 1 — Data

- [ ] Place the raw file at `data/raw/`, run `etl/transform.sql`, commit the seeds
      (the expected row counts are in the data spec)
- [ ] Flyway `V1__football_schema.sql`: DDL + indexes + `COMMENT ON` for every table and column
- [ ] Flyway `V2__app_schema.sql`: `app` schema from the architecture doc
- [ ] Flyway `V3__sandbox_grants.sql`: `GRANT USAGE/SELECT` on `football` to `hiddenxi_sandbox`
- [ ] Seeder (`seed` profile): truncate + `COPY` from gzip CSVs + `ANALYZE`, then exit
- [ ] `SeedIT` (Testcontainers): row counts and invariants from the data spec
- [ ] `catalog`: load table/column/type/comment metadata for schema `football`; `GET /api/schema`

**Done when:** a fresh clone can go from nothing to a seeded DB with two commands, `SeedIT` passes,
and `/api/schema` returns the 6 tables with descriptions.

---

## Phase 2 — Query sandbox

- [ ] Sandbox `DataSource` bean (`@Qualifier("sandbox")`, Hikari max 8, readOnly)
- [ ] `QueryValidator`: JSqlParser parse + allowlist visitors (statements, output contract,
      tables, functions, casts, operators, ID-range rule, IN-list cap, structural caps)
      returning `Accepted(statement, referencedPlayersColumns)` or `Rejected(code, message)`
- [ ] `PredicateColumnExtractor`: resolves `WHERE/ON/HAVING` column refs to `players` via aliases + catalog
- [ ] `QueryRewriter`: deparse + wrap
- [ ] `SandboxExecutor`: transaction, `SET LOCAL statement_timeout`, collect `Set<Integer>`, always rollback
- [ ] Error mapping to the codes in the security doc
- [ ] `corpus.yml` with all 30 starter cases; `QueryValidatorTest` (unit) + `SandboxExecutorIT`
      (each ACCEPT case runs; each rejected case run *directly* as the sandbox role is
      blocked or contained by role/timeouts)
- [ ] Dev-only endpoint `POST /api/dev/query` (profile `dev`) returning counts, for manual testing

**Done when:** the corpus passes end to end, the timeout is proven by test (cross-join case),
and the sandbox role provably cannot read `app.*`.

---

## Phase 3 — Game engine (pure domain)

- [ ] `prompts.yml` from `05-prompt-library.md`; `PromptLibrary` loads, validates via the sandbox,
      caches match sets; `PromptLibraryValidationIT` (counts equal `verifiedUniverseCount`, bounds 20..709)
- [ ] `UniverseCache`: all 2,837 `players` rows (+ club names) in memory for reveals
- [ ] `PoolBuilder` (seeded `Random`): algorithm and rejection rules from the architecture doc
- [ ] `Scorer`: R, hits, false positives, missed, Jaccard, exact
- [ ] `RevealEngine`: slots, column reveals (club name for `current_club_id`, `player_id`
      never), formatting, match chips
- [ ] Unit tests: pool sizes/overlap over all prompt pairs with fixed seeds (mirrors the
      simulation numbers), scoring edge cases (empty result, superset, exact), reveal truthfulness

**Done when:** a test can build a match for any prompt pair, score a guess, and produce
reveals, with no Spring context.

---

## Phase 4 — Practice mode (first playable)

Backend
- [ ] JPA entities/repos for `app.*`; `MatchService.createPractice()` (persists pool, group members, slots, seed)
- [ ] Guess pipeline (architecture doc, steps 1–8) incl. budget, interval, in-flight guard, CAS finish
- [ ] `MatchTimerScheduler` (timeout/budget finish)
- [ ] REST: `POST /api/practice`, `GET /api/matches/{id}`, `POST /api/matches/{id}/guesses`, `POST /api/matches/{id}/forfeit`
- [ ] Anonymous practice for now: a server-generated guest id in a cookie (real guest sessions come in Phase 5)

Frontend
- [ ] Home → Practice
- [ ] SQL editor: CodeMirror 6, PostgreSQL dialect, locked first line `SELECT player_id`,
      autocomplete from `/api/schema`, Ctrl/Cmd+Enter submits
- [ ] Board, guess log (click to reload SQL), counters (guesses left, timer, best Jaccard)
- [ ] Schema browser panel with descriptions + coverage notice
- [ ] Error display for validation codes (no guess consumed) vs timeouts (guess consumed)
- [ ] Summary screen: prompt, full group, canonical SQL vs your queries

**Playtest checkpoint (required before Phase 5):** play 10+ games across difficulties
yourself and with at least 2 friends. Record per prompt: solved?, guesses used, time.
Tune `guessBudget`, `matchDuration`, `poolSize`, `membersPerPrompt`, and difficulty
labels. Log changes in the decision log. If the core loop isn't fun, stop and redesign
the feedback/reveal rules before building Duel.

**Done when:** Practice is fully playable start to summary, tests are green, and the
playtest notes are in `docs/playtest-notes.md`.

---

## Phase 5 — Duel (real-time 1v1)

- [ ] Guest sessions: `POST /api/session {nickname}` → `app.users` row + HTTP session
      cookie; Spring Security permits guests, protects match endpoints by participant
- [ ] Lobby: `POST /api/duels` (invite code, 6 chars, no ambiguous characters), `POST /api/duels/join`
- [ ] Two-prompt pool via `PoolBuilder`; seats; `target(seat)` logic
- [ ] STOMP `/ws` endpoint; `ChannelInterceptor` authorizing `/topic/matches/{id}` subscriptions;
      events `MatchStarted`, `GuessEvaluated`, `PresenceChanged`, `MatchFinished`
- [ ] Publish events only **after** commit (`@TransactionalEventListener(phase = AFTER_COMMIT)`)
- [ ] Presence tracking + disconnect forfeit after 60 s
- [ ] Frontend: lobby screens, STOMP client with reconnect (re-fetch snapshot on reconnect),
      duel layout: your board of their group, their board of yours, your own group panel, shared guess log
- [ ] `ConcurrentWinIT`: simultaneous exact guesses → exactly one winner, other `LATE` (50 iterations)
- [ ] `DuelFlowIT`: two STOMP clients play a scripted match end to end

**Done when:** two browsers can play a full duel with live updates, reconnect mid-match,
and the concurrency test passes reliably.

---

## Phase 6 — Hardening and portfolio polish

- [ ] Real accounts (optional): register/login (BCrypt), guests can claim their history
- [ ] Rate limiting per session for all write endpoints; request size limits
- [ ] Metrics dashboard (Actuator + Micrometer): query latency p50/p95, rejections by code, timeouts
- [ ] Caching decision: measure repeated normalized queries; add Caffeine only if justified (record the decision)
- [ ] Docker images for backend and frontend; `docker compose up` runs everything; deploy somewhere cheap
- [ ] README: gameplay GIF, architecture diagram, "How the SQL sandbox works" section,
      data coverage and licensing notes, how to run, test strategy
- [ ] Optional stretch: a near-miss decoy difficulty mode; the transfer-based "active"
      rescue (decision #14 in the product spec), as a documented ETL feature

**Done when:** a stranger can clone, run, and play locally from the README, and you can
walk through the sandbox design in an interview.
