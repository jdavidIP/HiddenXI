-- =====================================================================
-- Hidden XI — ETL: Transfermarkt snapshot (DuckDB) -> cleaned seed CSVs
-- Dialect: DuckDB. Run from the repo root:
--   duckdb data/work.duckdb -c ".read etl/transform.sql"
-- Input : data/raw/transfermarkt-datasets.duckdb (snapshot current to 2026-07-06)
-- Output: data/seed/*.csv.gz (loaded into Postgres by the Java seeder)
-- Verified against the snapshot: players=2837, clubs=840, competitions=41,
--   games=78375, appearances=625854, transfers=26575.
-- See docs/02-data-spec.md for the reasoning behind every rule below.
-- =====================================================================
ATTACH 'data/raw/transfermarkt-datasets.duckdb' AS src (READ_ONLY);

-- 1. Competitions in scope: the 41 with player appearances for every season 2012/13–2025/26.
--    Curated names/categories (the source table has slug names, wrong types, and 4 missing ids).
CREATE OR REPLACE TABLE scope_competitions AS
SELECT * FROM (VALUES
 ('GB1','Premier League','league','England'),('ES1','LaLiga','league','Spain'),('IT1','Serie A','league','Italy'),
 ('L1','Bundesliga','league','Germany'),('FR1','Ligue 1','league','France'),('PO1','Liga Portugal','league','Portugal'),
 ('NL1','Eredivisie','league','Netherlands'),('BE1','Jupiler Pro League','league','Belgium'),('TR1','Süper Lig','league','Türkiye'),
 ('RU1','Russian Premier League','league','Russia'),('UKR1','Ukrainian Premier League','league','Ukraine'),('GR1','Super League Greece','league','Greece'),
 ('SC1','Scottish Premiership','league','Scotland'),('DK1','Danish Superliga','league','Denmark'),
 ('FAC','FA Cup','domestic_cup','England'),('CDR','Copa del Rey','domestic_cup','Spain'),('CIT','Coppa Italia','domestic_cup','Italy'),
 ('DFB','DFB-Pokal','domestic_cup','Germany'),('NLP','KNVB Cup','domestic_cup','Netherlands'),('POCP','Taça da Liga','domestic_cup','Portugal'),
 ('RUP','Russian Cup','domestic_cup','Russia'),('UKRP','Ukrainian Cup','domestic_cup','Ukraine'),('GRP','Greek Cup','domestic_cup','Greece'),
 ('SFA','Scottish Cup','domestic_cup','Scotland'),('DKP','Danish Cup','domestic_cup','Denmark'),
 ('GBCS','FA Community Shield','super_cup','England'),('SUC','Supercopa de España','super_cup','Spain'),('SCI','Supercoppa Italiana','super_cup','Italy'),
 ('DFL','DFL-Supercup','super_cup','Germany'),('FRCH','Trophée des Champions','super_cup','France'),('POSU','Supertaça Cândido de Oliveira','super_cup','Portugal'),
 ('NLSC','Johan Cruyff Shield','super_cup','Netherlands'),('BESC','Belgian Super Cup','super_cup','Belgium'),('RUSS','Russian Super Cup','super_cup','Russia'),
 ('UKRS','Ukrainian Super Cup','super_cup','Ukraine'),
 ('CL','UEFA Champions League','uefa','Europe'),('CLQ','UEFA Champions League Qualifying','uefa','Europe'),
 ('EL','UEFA Europa League','uefa','Europe'),('ELQ','UEFA Europa League Qualifying','uefa','Europe'),('USC','UEFA Super Cup','uefa','Europe'),
 ('KLUB','FIFA Club World Cup','fifa','World')
) t(competition_id, name, category, country);

-- 2. Country name normalization (variants coexist in the source; historical names were German labels).
CREATE OR REPLACE TABLE country_alias AS
SELECT * FROM (VALUES ('Turkey','Türkiye'),('Korea, South','South Korea'),('Curacao','Curaçao'),
 ('UdSSR','Soviet Union'),('Jugoslawien (SFR)','Yugoslavia (SFR)'),('CSSR','Czechoslovakia'),('Zaire','DR Congo'),
 ('Macedonia','North Macedonia'),('Swaziland','Eswatini'),('People''s republic of the Congo','Congo')) t(raw, canonical);

CREATE OR REPLACE MACRO canon(x) AS coalesce((SELECT canonical FROM country_alias WHERE raw = x), x);

-- 3. Appearances restricted to in-scope competitions (drops national-team, Conference League, EFL Cup, Belgian playoffs).
CREATE OR REPLACE TABLE apps_scope AS
SELECT a.* FROM src.appearances a WHERE a.competition_id IN (SELECT competition_id FROM scope_competitions);

-- 4. The player universe: active + European + notable.
CREATE OR REPLACE TABLE universe AS
SELECT p.player_id
FROM src.players p
JOIN (SELECT player_id, count(*) n,
             count(*) FILTER (WHERE competition_id IN (SELECT competition_id FROM scope_competitions WHERE category='league')) league_n
      FROM apps_scope GROUP BY 1) a USING (player_id)
WHERE p.last_season = '2025' AND a.league_n >= 1
  AND (a.n >= 150 OR p.highest_market_value_in_eur >= 15000000)
  AND coalesce(p.current_club_id, '') <> '123';  -- 123 = Transfermarkt "Retired" pseudo-club

-- 5. Target tables (normalized types, only what the game needs).
CREATE OR REPLACE TABLE players AS
SELECT p.player_id, trim(p.name) AS name, trim(p.first_name) AS first_name, trim(p.last_name) AS last_name,
       CAST(p.date_of_birth AS DATE) AS date_of_birth,
       canon(p.country_of_citizenship) AS country_of_citizenship, canon(p.country_of_birth) AS country_of_birth, nullif(trim(p.city_of_birth), '') AS city_of_birth,
       p.position, p.sub_position, p.foot, p.height_in_cm,
       CASE WHEN p.current_club_id = '515' THEN NULL                    -- 515 = "Without Club"
            ELSE TRY_CAST(p.current_club_id AS INTEGER) END AS current_club_id,
       p.market_value_in_eur, p.highest_market_value_in_eur,
       CAST(p.contract_expiration_date AS DATE) AS contract_expiration_date, nullif(trim(p.agent_name), '') AS agent_name,
       p.international_caps, p.international_goals
FROM src.players p JOIN universe USING (player_id);

CREATE OR REPLACE TABLE clubs AS
SELECT CAST(club_id AS INTEGER) club_id, name, domestic_competition_id, stadium_name, stadium_seats
FROM src.clubs;

CREATE OR REPLACE TABLE games AS
SELECT CAST(g.game_id AS INTEGER) game_id, g.competition_id, CAST(g.season AS INTEGER) season, g.round, CAST(g.date AS DATE) AS date,
       g.home_club_id, g.away_club_id, g.home_club_name, g.away_club_name, g.home_club_goals, g.away_club_goals,
       g.home_club_manager_name, g.away_club_manager_name, g.stadium, g.attendance, g.referee
FROM src.games g WHERE g.competition_id IN (SELECT competition_id FROM scope_competitions);

CREATE OR REPLACE TABLE appearances AS
SELECT a.appearance_id, a.game_id, a.player_id, a.player_club_id AS club_id, a.competition_id, CAST(a.date AS DATE) AS date,
       a.goals, a.assists, a.yellow_cards, a.red_cards, a.minutes_played
FROM apps_scope a JOIN universe USING (player_id);

CREATE OR REPLACE TABLE transfers AS
SELECT t.player_id, t.transfer_date, t.transfer_season, t.from_club_id, t.from_club_name, t.to_club_id, t.to_club_name,
       CAST(t.transfer_fee AS BIGINT) transfer_fee, CAST(t.market_value_in_eur AS BIGINT) market_value_in_eur
FROM src.transfers t JOIN universe USING (player_id)
WHERE t.transfer_date <= DATE '2026-07-06';

CREATE OR REPLACE TABLE competitions AS SELECT * FROM scope_competitions;

-- Stub rows for current clubs the scraper does not track (players who moved mid-2025/26).
INSERT INTO clubs
SELECT DISTINCT p.current_club_id, coalesce(n.name, 'Unknown club ' || p.current_club_id), NULL, NULL, NULL
FROM players p
LEFT JOIN (SELECT to_club_id, any_value(to_club_name) AS name FROM transfers GROUP BY 1) n ON n.to_club_id = p.current_club_id
WHERE p.current_club_id IS NOT NULL AND p.current_club_id NOT IN (SELECT club_id FROM clubs);

-- Export seed files for the Java seeder (gzip CSV, header row, NULL = empty field)
COPY competitions TO 'data/seed/competitions.csv.gz' (HEADER, COMPRESSION gzip);
COPY clubs TO 'data/seed/clubs.csv.gz' (HEADER, COMPRESSION gzip);
COPY players TO 'data/seed/players.csv.gz' (HEADER, COMPRESSION gzip);
COPY games TO 'data/seed/games.csv.gz' (HEADER, COMPRESSION gzip);
COPY appearances TO 'data/seed/appearances.csv.gz' (HEADER, COMPRESSION gzip);
COPY transfers TO 'data/seed/transfers.csv.gz' (HEADER, COMPRESSION gzip);
