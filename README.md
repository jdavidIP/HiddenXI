# Hidden XI

A real-time 1v1 deduction game played with SQL. Each player is secretly given a group of
footballers defined by a prompt ("played for Real Madrid", "100+ caps"). You write SQL
against a football database to work out your opponent's group. Every query is scored
against the hidden group, and the first query that returns exactly that group wins.

> Work in progress. See `docs/06-implementation-plan.md` for the current phase.

## Stack

Java 25 · Spring Boot 4 · PostgreSQL 18 · React + TypeScript + Vite · Tailwind · Docker Compose

## Run locally

Prerequisites: Docker, JDK 25+, Node 24+.

```bash
cp .env.example .env                           # then change the passwords
docker compose up -d db                        # Postgres on :5432
cd backend && ./mvnw spring-boot:run           # API on :8080 -> /actuator/health
cd frontend && npm install && npm run dev      # UI on :5173
```

## Tests

```bash
cd backend && ./mvnw verify                    # needs Docker (Testcontainers)
cd frontend && npm test && npm run lint && npm run typecheck
```

## Docs

The specs in [`docs/`](docs/) are the source of truth: product rules, data, architecture,
the SQL sandbox's security model, the prompt library, and the implementation plan.
