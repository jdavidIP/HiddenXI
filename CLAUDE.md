# Hidden XI (working title)

A real-time 1v1 deduction game played with SQL. Each player is secretly assigned a
group of football players defined by a prompt ("played for Real Madrid", "100+ caps").
Players write SQL queries against a football database to deduce the *opponent's* group.
Every query is scored against the hidden group; the first player whose query returns
exactly the opponent's group wins.

The owner is building this to learn SQL and Java/Spring Boot and to have a strong
portfolio project. Prefer clear, idiomatic, well-tested code over clever code. When you
introduce a Spring or SQL concept for the first time, explain it briefly in your summary.

## Source of truth

The specs in `docs/` are the source of truth. Read the relevant ones before starting work:

| Doc | Read when |
|---|---|
| `docs/01-product-spec.md` | Anything touching game rules, scoring, reveals, UI behavior |
| `docs/02-data-spec.md` | ETL, schema, seeding, anything about what the data means |
| `docs/03-architecture.md` | Backend/frontend structure, APIs, WebSocket events, concurrency |
| `docs/04-sandbox-security.md` | Anything that executes, parses, or rewrites user SQL |
| `docs/05-prompt-library.md` | Adding/editing prompts, prompt validation |
| `docs/06-implementation-plan.md` | Choosing what to do next; phase checklists and definitions of done |

If a spec is ambiguous or seems wrong, stop and ask. Do not silently change game rules,
data rules, or security rules. When a decision changes, update the doc and add an entry
to the decision log at the bottom of `docs/01-product-spec.md`.

## Tech stack

- Backend: Java 25 (LTS), Spring Boot 4.x (latest patch), Maven wrapper
  - Spring Web MVC, Spring WebSocket (STOMP), Spring Security, Spring Data JPA (app data
    only), JdbcTemplate (sandbox queries), Flyway (+ PostgreSQL module), Actuator
  - JSqlParser (latest 5.x) for parsing/validating user SQL
  - Tests: JUnit 5, AssertJ, Testcontainers (PostgreSQL)
  - Boot 4 uses Jackson 3 and modular starters. Do not copy Boot 3 snippets blindly;
    check the Boot 4 docs when unsure.
- Database: PostgreSQL 18 (Docker), two schemas: `football` (read-only game data) and
  `app` (users, matches, guesses)
- Frontend: React + TypeScript (strict) + Vite, CodeMirror 6 (SQL editor), @stomp/stompjs,
  TanStack Query, Zustand, Tailwind CSS. Tests: Vitest + Testing Library.
- ETL: DuckDB CLI running `etl/transform.sql` (one-off, output committed)
- Infra: Docker Compose for local dev; GitHub Actions CI

## Repository layout

```
CLAUDE.md
docs/                     specs (source of truth)
etl/transform.sql         DuckDB ETL: raw snapshot -> data/seed/*.csv.gz
data/raw/                 raw Transfermarkt DuckDB file (gitignored, 210 MB)
data/seed/                cleaned seed CSVs, gzip (committed, ~10 MB)
backend/                  Spring Boot app (package root: com.hiddenxi)
frontend/                 React app
infra/db/init/            Postgres init scripts (database + roles)
docker-compose.yml        postgres (+ backend/frontend later)
```

## Commands

Keep this section updated as commands become real.

```bash
cp .env.example .env                                     # once; DB passwords read by compose AND Spring
docker compose up -d db                                  # start Postgres (init script runs only on an empty volume)
docker compose down -v                                   # wipe the DB volume (needed after changing passwords)
duckdb data/work.duckdb -c ".read etl/transform.sql"     # regenerate seeds (rarely needed)
cd backend && ./mvnw spring-boot:run -Dspring-boot.run.profiles=seed   # load seeds into Postgres (Phase 1)
cd backend && ./mvnw spring-boot:run                     # run API on :8080
cd backend && ./mvnw verify                              # unit + integration tests
cd frontend && npm run dev                               # Vite dev server on :5173 (proxies /api, /ws)
cd frontend && npm test && npm run lint && npm run typecheck
```

## Non-negotiable rules

Security and game integrity (details in `docs/04-sandbox-security.md`):
1. User SQL is executed only through the sandbox pipeline: validate (allowlist) → rewrite
   (wrapper) → execute on the read-only sandbox DataSource. No other code path may run user SQL.
2. The sandbox DataSource connects as the `hiddenxi_sandbox` role, which can only `SELECT`
   from schema `football`. Never use the app/owner DataSource for user SQL.
3. Never send hidden-group player IDs, names, or unrevealed attributes to a client that is
   guessing that group. Clients see opaque slot numbers (1..N) and only what reveals allow.
   Full identities are sent only after the match ends.
4. Never concatenate user input into SQL anywhere except the single documented wrapper,
   and only after the validator has accepted the query.
5. Never echo raw database exception messages to clients. Map them to safe messages.

Data (details in `docs/02-data-spec.md`):
6. The football data is a frozen snapshot (2025/26 season, current to 2026-07-06). Do not
   hand-edit facts. Fixes go in `etl/transform.sql`, with seeds regenerated.
7. Stats cover only "tracked European club competitions, 2012/13–2025/26". Any UI copy that
   mentions stats must say so.

## Conventions

- Java: constructor injection, `record`s for DTOs/events/value objects, no Lombok.
  Package by feature (`sandbox`, `game`, `match`, `realtime`, `catalog`, `seed`, `account`).
- Domain logic (pool building, scoring, reveals) is plain Java with no Spring or DB
  dependencies, so it can be unit-tested deterministically (inject `Random`/`Clock`).
- Every Flyway migration is immutable once merged. New change = new migration.
- Configurable game constants live in `application.yml` under `hiddenxi.game.*`
  (see product spec "Tunable defaults"), never hard-coded.
- Frontend: function components, hooks, no `any`. Server state via TanStack Query; match
  state (WebSocket events) via a Zustand store.
- Commits: small and focused, imperative subject line. Run the relevant tests before
  saying a task is done.

## Workflow

Process rules (commits, branches, PRs, issues) live in `docs/CLAUDE_WORKFLOW.md`. Read it
at the start of every session and follow it.

1. Find the current phase in `docs/06-implementation-plan.md` and the next unchecked task.
2. Read the docs that task depends on. Propose a short plan before large changes.
3. Implement with tests. For anything in the sandbox, add cases to the security test corpus.
4. Check the task off in the plan, and update docs if anything changed.
