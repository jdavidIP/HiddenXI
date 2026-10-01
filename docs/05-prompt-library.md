# 05 — Prompt Library

A **prompt** is a curated group definition: a title the owner sees, a description, a
difficulty, and one canonical SQL query over the `football` schema returning `player_id`.
Prompts are game content, so they're versioned with the code in
`backend/src/main/resources/prompts/prompts.yml`.

## Rules every prompt must satisfy (enforced by `PromptLibraryValidationIT`)

1. The SQL passes the **same sandbox validator** as player queries and runs through the
   sandbox executor. Prompts dogfood the sandbox.
2. Universe match count between **20** and **709** (25% of 2,837). Below 20, groups get too
   small after sampling. Above 25%, decoy selection gets skewed.
3. Deterministic: no ordering-dependent `LIMIT`, no non-deterministic functions.
4. Only uses data the data spec calls reliable:
   - stats only from in-scope competitions (always the case: the schema only contains them)
   - `transfer_fee` only with thresholds > 0 (0 means free **or** loan)
   - `games.round` only as `'Final'` (other labels are inconsistent)
   - no national-team match data (there is none in the schema); caps/goals from `players` only
5. Literal IDs are allowed only for well-known entities (418 Real Madrid, 131 Barcelona,
   281 Manchester City, 985 Manchester United, 28003 Lionel Messi). The entity must be
   named in the title or description, since SQL comments are dropped by the deparser.
6. Descriptions must be truthful under the coverage caveat ("in tracked competitions
   since 2012/13" wherever stats are involved).
7. The `verifiedUniverseCount` in the YAML must equal the live count. The test fails if the
   data or the SQL changes without updating it.

At startup, `PromptLibrary` loads the YAML, executes every prompt once, and caches
`promptId → Set<player_id>`. If any prompt fails validation, startup fails, so a broken
prompt never reaches a match.

## Starter library (28 prompts, verified against the final universe)

| ID | Difficulty | Title | Universe matches |
|---|---|---|---|
| E01 | easy | Left-footed goalkeepers | 29 |
| E02 | easy | 100+ international caps | 98 |
| E03 | easy | 30+ international goals | 58 |
| E04 | easy | Outfield players 1.93 m or taller | 127 |
| E05 | easy | Players 1.70 m or shorter | 120 |
| E06 | easy | Two-footed players | 89 |
| E07 | easy | Represented by Gestifute | 58 |
| E08 | easy | Peak market value of €100M+ | 56 |
| E09 | easy | Brazilian centre-backs | 33 |
| E10 | easy | Born in 1990 or earlier | 273 |
| M01 | medium | Played for Real Madrid | 67 |
| M02 | medium | Champions League hat-trick | 46 |
| M03 | medium | Sent off in the Champions League | 49 |
| M04 | medium | Transferred for €50M+ | 147 |
| M05 | medium | Currently in the Saudi Pro League | 79 |
| M06 | medium | Played at the FIFA Club World Cup | 321 |
| M07 | medium | Played in a Champions League final | 168 |
| M08 | medium | Played in the Scottish Premiership | 136 |
| H01 | hard | 100+ goals in tracked competitions | 118 |
| H02 | hard | Played in both LaLiga and the Premier League | 203 |
| H03 | hard | Played in 4+ different tracked leagues | 275 |
| H04 | hard | 250+ appearances, never sent off | 421 |
| H05 | hard | Paid transfer between two Premier League clubs | 224 |
| H06 | hard | 15+ assists in a single league season | 47 |
| H07 | hard | Played for 6+ different clubs | 370 |
| H08 | hard | Played alongside Lionel Messi | 65 |
| H09 | hard | Scored against Real Madrid | 243 |
| H10 | hard | Scored in 4+ different competitions in one season | 221 |

Difficulty is a first guess based on how many joins/aggregates the answer needs.
Retune after playtesting by looking at guesses-to-solve per prompt.

Pool simulation with defaults (pool 500, 30 members per prompt, overlap cap 0.3) over all
378 pairs: groups of 29–45 players (median 31); 21 pairs rejected for overlap.

## `prompts.yml`

```yaml
- id: E01
  difficulty: easy
  title: "Left-footed goalkeepers"
  description: "Goalkeepers whose stronger foot is the left."
  sql: |
    SELECT player_id FROM players WHERE position = 'Goalkeeper' AND foot = 'left'
  verifiedUniverseCount: 29

- id: E02
  difficulty: easy
  title: "100+ international caps"
  description: "Players with at least 100 senior international caps (profile data)."
  sql: |
    SELECT player_id FROM players WHERE international_caps >= 100
  verifiedUniverseCount: 98

- id: E03
  difficulty: easy
  title: "30+ international goals"
  description: "Players with at least 30 senior international goals (profile data)."
  sql: |
    SELECT player_id FROM players WHERE international_goals >= 30
  verifiedUniverseCount: 58

- id: E04
  difficulty: easy
  title: "Outfield players 1.93 m or taller"
  description: "Non-goalkeepers listed at 193 cm or taller."
  sql: |
    SELECT player_id FROM players WHERE height_in_cm >= 193 AND position <> 'Goalkeeper'
  verifiedUniverseCount: 127

- id: E05
  difficulty: easy
  title: "Players 1.70 m or shorter"
  description: "Players listed at 170 cm or shorter."
  sql: |
    SELECT player_id FROM players WHERE height_in_cm <= 170
  verifiedUniverseCount: 120

- id: E06
  difficulty: easy
  title: "Two-footed players"
  description: "Players listed as two-footed."
  sql: |
    SELECT player_id FROM players WHERE foot = 'both'
  verifiedUniverseCount: 89

- id: E07
  difficulty: easy
  title: "Represented by Gestifute"
  description: "Players whose agency is Gestifute."
  sql: |
    SELECT player_id FROM players WHERE agent_name = 'Gestifute'
  verifiedUniverseCount: 58

- id: E08
  difficulty: easy
  title: "Peak market value of €100M+"
  description: "Players whose market value peaked at €100M or more."
  sql: |
    SELECT player_id FROM players WHERE highest_market_value_in_eur >= 100000000
  verifiedUniverseCount: 56

- id: E09
  difficulty: easy
  title: "Brazilian centre-backs"
  description: "Brazilian citizens whose sub-position is Centre-Back."
  sql: |
    SELECT player_id FROM players WHERE country_of_citizenship = 'Brazil' AND sub_position = 'Centre-Back'
  verifiedUniverseCount: 33

- id: E10
  difficulty: easy
  title: "Born in 1990 or earlier"
  description: "Players born before 1 January 1991."
  sql: |
    SELECT player_id FROM players WHERE date_of_birth < DATE '1991-01-01'
  verifiedUniverseCount: 273

- id: M01
  difficulty: medium
  title: "Played for Real Madrid"
  description: "Appeared for Real Madrid in a tracked competition (2012/13–2025/26)."
  sql: |
    SELECT DISTINCT player_id FROM appearances WHERE club_id = 418
  verifiedUniverseCount: 67

- id: M02
  difficulty: medium
  title: "Champions League hat-trick"
  description: "Scored 3+ goals in a single Champions League match."
  sql: |
    SELECT DISTINCT player_id FROM appearances WHERE competition_id = 'CL' AND goals >= 3
  verifiedUniverseCount: 46

- id: M03
  difficulty: medium
  title: "Sent off in the Champions League"
  description: "Received a red card in a Champions League match."
  sql: |
    SELECT DISTINCT player_id FROM appearances WHERE competition_id = 'CL' AND red_cards > 0
  verifiedUniverseCount: 49

- id: M04
  difficulty: medium
  title: "Transferred for €50M+"
  description: "Had at least one transfer with a fee of €50M or more."
  sql: |
    SELECT DISTINCT player_id FROM transfers WHERE transfer_fee >= 50000000
  verifiedUniverseCount: 147

- id: M05
  difficulty: medium
  title: "Currently in the Saudi Pro League"
  description: "Current club plays in the Saudi Pro League."
  sql: |
    SELECT p.player_id FROM players p JOIN clubs c ON c.club_id = p.current_club_id WHERE c.domestic_competition_id = 'SA1'
  verifiedUniverseCount: 79

- id: M06
  difficulty: medium
  title: "Played at the FIFA Club World Cup"
  description: "Appeared at a FIFA Club World Cup (tracked editions)."
  sql: |
    SELECT DISTINCT player_id FROM appearances WHERE competition_id = 'KLUB'
  verifiedUniverseCount: 321

- id: M07
  difficulty: medium
  title: "Played in a Champions League final"
  description: "Appeared in a Champions League final (2012/13–2025/26)."
  sql: |
    SELECT DISTINCT a.player_id FROM appearances a JOIN games g ON g.game_id = a.game_id WHERE g.competition_id = 'CL' AND g.round = 'Final'
  verifiedUniverseCount: 168

- id: M08
  difficulty: medium
  title: "Played in the Scottish Premiership"
  description: "Appeared in the Scottish Premiership."
  sql: |
    SELECT DISTINCT player_id FROM appearances WHERE competition_id = 'SC1'
  verifiedUniverseCount: 136

- id: H01
  difficulty: hard
  title: "100+ goals in tracked competitions"
  description: "Scored 100+ goals across tracked competitions since 2012/13."
  sql: |
    SELECT player_id FROM appearances GROUP BY player_id HAVING SUM(goals) >= 100
  verifiedUniverseCount: 118

- id: H02
  difficulty: hard
  title: "Played in both LaLiga and the Premier League"
  description: "Appeared in both LaLiga and the Premier League."
  sql: |
    SELECT player_id FROM appearances WHERE competition_id IN ('ES1','GB1') GROUP BY player_id HAVING COUNT(DISTINCT competition_id) = 2
  verifiedUniverseCount: 203

- id: H03
  difficulty: hard
  title: "Played in 4+ different tracked leagues"
  description: "Appeared in at least 4 different tracked top-flight leagues."
  sql: |
    SELECT a.player_id FROM appearances a JOIN competitions c ON c.competition_id = a.competition_id WHERE c.category = 'league' GROUP BY a.player_id HAVING COUNT(DISTINCT a.competition_id) >= 4
  verifiedUniverseCount: 275

- id: H04
  difficulty: hard
  title: "250+ appearances, never sent off"
  description: "250+ tracked appearances without a single red card."
  sql: |
    SELECT player_id FROM appearances GROUP BY player_id HAVING COUNT(*) >= 250 AND SUM(red_cards) = 0
  verifiedUniverseCount: 421

- id: H05
  difficulty: hard
  title: "Paid transfer between two Premier League clubs"
  description: "Moved between two Premier League clubs for a fee."
  sql: |
    SELECT DISTINCT t.player_id FROM transfers t JOIN clubs f ON f.club_id = t.from_club_id JOIN clubs d ON d.club_id = t.to_club_id WHERE f.domestic_competition_id = 'GB1' AND d.domestic_competition_id = 'GB1' AND t.transfer_fee > 0
  verifiedUniverseCount: 224

- id: H06
  difficulty: hard
  title: "15+ assists in a single league season"
  description: "Recorded 15+ assists in one league in one season."
  sql: |
    SELECT DISTINCT a.player_id FROM appearances a JOIN games g ON g.game_id = a.game_id JOIN competitions c ON c.competition_id = a.competition_id WHERE c.category = 'league' GROUP BY a.player_id, g.season, a.competition_id HAVING SUM(a.assists) >= 15
  verifiedUniverseCount: 47

- id: H07
  difficulty: hard
  title: "Played for 6+ different clubs"
  description: "Appeared for 6+ different clubs in tracked competitions."
  sql: |
    SELECT player_id FROM appearances GROUP BY player_id HAVING COUNT(DISTINCT club_id) >= 6
  verifiedUniverseCount: 370

- id: H08
  difficulty: hard
  title: "Played alongside Lionel Messi"
  description: "Appeared in the same match, for the same club, as Lionel Messi."
  sql: |
    SELECT DISTINCT a.player_id FROM appearances a JOIN appearances m ON m.game_id = a.game_id AND m.club_id = a.club_id WHERE m.player_id = 28003 AND a.player_id <> 28003
  verifiedUniverseCount: 65

- id: H09
  difficulty: hard
  title: "Scored against Real Madrid"
  description: "Scored in a match against Real Madrid."
  sql: |
    SELECT DISTINCT a.player_id FROM appearances a JOIN games g ON g.game_id = a.game_id WHERE a.goals > 0 AND a.club_id <> 418 AND (g.home_club_id = 418 OR g.away_club_id = 418)
  verifiedUniverseCount: 243

- id: H10
  difficulty: hard
  title: "Scored in 4+ different competitions in one season"
  description: "Scored in 4+ different competitions within a single season."
  sql: |
    SELECT DISTINCT a.player_id FROM appearances a JOIN games g ON g.game_id = a.game_id WHERE a.goals > 0 GROUP BY a.player_id, g.season HAVING COUNT(DISTINCT a.competition_id) >= 4
  verifiedUniverseCount: 221
```

## Ideas for the next batch (validate before adding)

- Played for both <club A> and <club B> (pick pairs with ≥ 20 matches; Real Madrid + Barcelona has only 2)
- Scored in a domestic cup final (`round = 'Final'` and category `domestic_cup`)
- Born in a different country than their citizenship. Careful: historical birth
  countries ("Soviet Union", "Yugoslavia (SFR)") make naive comparisons misleading;
  exclude those or define it explicitly
- Contract expires in 2027
- Represented by <other big agency> (THE·TEAM 123, CAA Stellar 73, ROOF 54…)
- Played under a specific manager (from `games.*_manager_name`, matching the player's side)
