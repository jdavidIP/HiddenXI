# 02 — Data Spec

## Source

- **Dataset:** `dcaribou/transfermarkt-datasets` (GitHub/Kaggle), distributed as a single
  DuckDB file. The compilation is CC0. The underlying data is scraped from Transfermarkt,
  so check Transfermarkt's terms before any public hosting.
- **Snapshot:** updates are paused. Data is current to **2026-07-06**. Appearances end
  2026-06-28. No 2026/27 squads.
- **Location:** `data/raw/transfermarkt-datasets.duckdb` (gitignored). The cleaned output
  `data/seed/*.csv.gz` is committed (~10 MB), so a clone works without the raw file.

The data is frozen, which is good for this game: prompts don't drift, group sizes stay
valid, tests are reproducible, and there's no ingestion pipeline to maintain.

## Findings that shaped the rules (verified against the snapshot)

| Finding | Consequence |
|---|---|
| 41% of the 50,149 players have zero appearances (youth/squad filler) | Need a notability rule |
| Player appearances exist only for 41 competitions over all of 2012/13–2025/26; 21 competitions have **no** appearance rows (MLS, Saudi Pro League, Brasileirão, Argentina, Liga MX, J1, K League, Austria, Switzerland, English Championship, Euro, Copa América, Conference League main stage…) | Stats = "tracked European club competitions since 2012/13" |
| A few competitions are only partially covered: Conference League qualifiers (2021+), EFL Cup (2022+), Belgian playoff rounds (2025 only) | Excluded for consistency |
| National-team appearances: only the 2026 World Cup group stage and AFCON 2025 | No national-team match data in the game |
| `players.international_caps/goals` are reasonably complete (93% in the universe), and citizenship matched the team actually played for in all 987 checked World Cup cases | International football kept as profile attributes |
| `current_national_team_id` is mostly empty | Dropped |
| `last_season` only updates for clubs the scraper visits (32 leagues, including MLS and Saudi, but not Qatar/UAE/lower divisions) | "Active" = in a scraped squad in 2025/26. Players who moved to unscraped leagues are excluded (accepted limitation) |
| Transfer history exists only for players seen in 2023+ (fine here: the universe is all active players, and 2,821 of 2,837 have transfers) | Transfers are reliable within the universe |
| `transfer_fee`: NULL = unknown; 0 = free transfer **or** loan (no transfer-type column); fees in EUR | Prompts use fee thresholds > 0 only |
| 520 transfers are dated after the snapshot (up to 2030; planned loan returns) | Cut at 2026-07-06 |
| ID types are inconsistent: `club_id` text vs integer, `game_id` integer vs text | Normalized to integer |
| Country variants coexist: `Turkey` and `Türkiye` (both in citizenship), `Korea, South`, `Curacao`; historical birth countries have German labels (`UdSSR`, `Jugoslawien (SFR)`, `CSSR`) | Alias table in ETL |
| `competitions` has slug names, inconsistent types (EL = "other"), and 4 ids used by appearances are missing (POCP, KLUB, UKRS, CGB) | Curated 41-row competitions table in ETL |
| Domestic cup coverage is uneven: no Coupe de France, Turkish Cup, Belgian Cup, or Taça de Portugal (Portugal has only Taça da Liga = POCP) | "All competitions" totals favor some countries; note in prompt design |
| Club World Cup: annual editions, none in 2024, the 2025 expanded edition (63 games). Ukrainian Super Cup last played in 2021 | Accurate, just uneven |
| CL `round` labels are inconsistent in casing ("Semi-Finals 1st Leg" vs "last 16 1st leg") | Prompts on rounds must match exact strings; only `round = 'Final'` is used |
| Player names are not unique (10 duplicates in the universe: Pedro ×3, Danilo ×3, Aaron Ramsey ×2…) | UI shows club + birth year next to names |
| 57 universe players' current club is missing from `clubs` (moved to untracked clubs mid-season); ids 123 = "Retired", 515 = "Without Club" | ETL adds stub club rows (name from transfers); 515 → NULL; current club 123 → excluded |
| 32 universe players retired at the end of 2025/26 (e.g. James Milner, transfer to "Retired" dated 2026-07-01) | Kept: they were active in 2025/26 |

## The universe

A player is in the game if **all** of these hold:

1. **Active:** `last_season = '2025'` (in a scraped club's 2025/26 squad), and current
   club is not "Retired" (id 123).
2. **European:** at least 1 appearance in one of the 14 tracked top-flight leagues.
3. **Notable:** 150+ appearances in in-scope competitions, **or** peak market value ≥ €15M.

Result: **2,837 players**, with a healthy age spread (544 under 25, 746 aged 25–28,
872 aged 29–32, 675 aged 33+). Bio columns (birth date, citizenship, birthplace, position,
foot, height, market values) are ~100% complete. International caps/goals are 93%,
contract expiry 86%, agent 75%.

### In-scope competitions (41)

- **Leagues (14):** GB1 Premier League, ES1 LaLiga, IT1 Serie A, L1 Bundesliga,
  FR1 Ligue 1, PO1 Liga Portugal, NL1 Eredivisie, BE1 Jupiler Pro League, TR1 Süper Lig,
  RU1 Russian Premier League, UKR1 Ukrainian Premier League, GR1 Super League Greece,
  SC1 Scottish Premiership, DK1 Danish Superliga
- **Domestic cups (11):** FAC, CDR, CIT, DFB, NLP, POCP (Taça da Liga), RUP, UKRP, GRP, SFA, DKP
- **Super cups (10):** GBCS, SUC, SCI, DFL, FRCH, POSU, NLSC, BESC, RUSS, UKRS
- **UEFA (5):** CL, CLQ, EL, ELQ, USC
- **FIFA (1):** KLUB (Club World Cup)

Category values in `competitions.category`: `league`, `domestic_cup`, `super_cup`, `uefa`, `fifa`.

## ETL

`etl/transform.sql` (DuckDB) is the single, verified implementation of everything above.
Run it from the repo root:

```bash
duckdb data/work.duckdb -c ".read etl/transform.sql"
```

It writes `data/seed/{competitions,clubs,players,games,appearances,transfers}.csv.gz`
(header row, NULL = empty unquoted field, dates ISO `YYYY-MM-DD`).

Expected row counts (the seeder's integration test asserts these):

| Table | Rows |
|---|---|
| competitions | 41 |
| clubs | 840 (796 source + 44 stubs) |
| players | 2,837 |
| games | 78,375 |
| appearances | 625,854 |
| transfers | 26,575 |

## Target schema (PostgreSQL, schema `football`)

Created by Flyway (`V1__football_schema.sql`). Loaded by the Java seeder. Column names
match the CSV headers. Comments become the schema-browser descriptions (`COMMENT ON`).

```sql
CREATE SCHEMA football;

CREATE TABLE football.competitions (
  competition_id text PRIMARY KEY,
  name           text NOT NULL,
  category       text NOT NULL CHECK (category IN ('league','domestic_cup','super_cup','uefa','fifa')),
  country        text NOT NULL            -- 'Europe' for UEFA, 'World' for FIFA
);

CREATE TABLE football.clubs (
  club_id                 integer PRIMARY KEY,
  name                    text NOT NULL,
  domestic_competition_id text,           -- no FK: includes untracked leagues ('SA1','MLS1',…); NULL for stubs
  stadium_name            text,
  stadium_seats           integer
);

CREATE TABLE football.players (
  player_id                   integer PRIMARY KEY,
  name                        text NOT NULL,  -- not unique
  first_name                  text,
  last_name                   text,
  date_of_birth               date,
  country_of_citizenship      text,
  country_of_birth            text,
  city_of_birth               text,
  position                    text,           -- Goalkeeper | Defender | Midfield | Attack
  sub_position                text,           -- e.g. Centre-Back, Left Winger
  foot                        text,           -- left | right | both
  height_in_cm                integer,
  current_club_id             integer REFERENCES football.clubs,
  market_value_in_eur         bigint,         -- as of 2025/26
  highest_market_value_in_eur bigint,
  contract_expiration_date    date,
  agent_name                  text,
  international_caps          integer,        -- NULL = unknown
  international_goals          integer
);

CREATE TABLE football.games (
  game_id                integer PRIMARY KEY,
  competition_id         text NOT NULL REFERENCES football.competitions,
  season                 integer NOT NULL,      -- start year: 2012 = 2012/13
  round                  text,
  date                   date NOT NULL,
  home_club_id           integer NOT NULL,      -- no FK: European opponents may be untracked
  away_club_id           integer NOT NULL,
  home_club_name         text,
  away_club_name         text,
  home_club_goals        integer,
  away_club_goals        integer,
  home_club_manager_name text,
  away_club_manager_name text,
  stadium                text,
  attendance             integer,
  referee                text
);

CREATE TABLE football.appearances (
  appearance_id  text PRIMARY KEY,
  game_id        integer NOT NULL REFERENCES football.games,
  player_id      integer NOT NULL REFERENCES football.players,
  club_id        integer NOT NULL,              -- club the player played for in that game
  competition_id text NOT NULL REFERENCES football.competitions,
  date           date NOT NULL,
  goals          integer NOT NULL,
  assists        integer NOT NULL,
  yellow_cards   integer NOT NULL,
  red_cards      integer NOT NULL,
  minutes_played integer NOT NULL
);

CREATE TABLE football.transfers (
  transfer_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_id           integer NOT NULL REFERENCES football.players,
  transfer_date       date NOT NULL,
  transfer_season     text,                    -- e.g. '25/26'
  from_club_id        integer,                 -- may be 123 Retired, 515 Without Club, or untracked
  from_club_name      text,
  to_club_id          integer,
  to_club_name        text,
  transfer_fee        bigint,                  -- EUR; NULL unknown; 0 free OR loan
  market_value_in_eur bigint
);

CREATE INDEX ON football.appearances (player_id);
CREATE INDEX ON football.appearances (game_id);
CREATE INDEX ON football.appearances (club_id);
CREATE INDEX ON football.appearances (competition_id, player_id);
CREATE INDEX ON football.games (competition_id, season);
CREATE INDEX ON football.games (home_club_id);
CREATE INDEX ON football.games (away_club_id);
CREATE INDEX ON football.transfers (player_id);
CREATE INDEX ON football.transfers (to_club_id);
CREATE INDEX ON football.transfers (from_club_id);
CREATE INDEX ON football.players (current_club_id);
```

Add `COMMENT ON TABLE/COLUMN` for every table and column. The descriptions above, plus
units and caveats, are what players read in the schema browser.

## Seeder

- Spring profile `seed`: a `CommandLineRunner` that, in one transaction, `TRUNCATE`s the
  `football` tables (in FK order) and loads each `data/seed/*.csv.gz` with PostgreSQL
  `COPY ... FROM STDIN (FORMAT csv, HEADER true)` via `CopyManager` (unwrap `PgConnection`),
  streaming through `GZIPInputStream`. Pass an explicit column list read from the header
  (transfers omits `transfer_id`). Then `ANALYZE` and exit.
- Runs as the owner role, never as the sandbox role.
- Integration test (Testcontainers): run the seeder and assert the row counts above, plus
  invariants: no orphan FKs, every player has ≥ 1 league appearance, no transfer after
  2026-07-06, no `Turkey`/`Korea, South` left in country columns.
