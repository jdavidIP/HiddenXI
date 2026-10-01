# 01 — Product Spec

## Concept

Hidden XI is a deduction game played with SQL on a database of ~2,800 active European
footballers. Each player owns a secret **group** of footballers defined by a **prompt**
(e.g. "Played for Real Madrid"). You never see your opponent's prompt. You write SQL
queries; each query is scored against the opponent's group, and matched members are
gradually revealed on a board. The first player to submit a query that returns *exactly*
the opponent's group wins.

The fun is pattern-spotting: chipping away at "what do these players have in common?"
using whatever SQL you can write: filters, joins, aggregates, set operations.

## Glossary

| Term | Meaning |
|---|---|
| Universe | All footballers in the game database (2,837). See `02-data-spec.md`. |
| Prompt | A curated, named definition with a canonical SQL query, e.g. "100+ international caps". |
| Pool | The subset of the universe used in one match (default 500 players). Shared by both players. |
| Group | The players in the pool matching a prompt. Each player owns one group. |
| Decoys | Pool players that match neither prompt. |
| Guess | One SQL query submitted by a player. |
| Result set (R) | The guess's player IDs, intersected with the pool. |
| Hits | R ∩ target group. |
| False positives | R minus the target group. |
| Missed | Target group minus R. |
| Board | The guesser's view of the target group: N slots that fill in as members are hit. |
| Slot | An opaque 1..N position for one hidden member. Stable for the whole match. |
| Jaccard | \|R ∩ G\| / \|R ∪ G\|. Used for tiebreaks and progress display. |

## Modes

1. **Practice (single-player).** You against one randomly assigned prompt. No opponent,
   no WebSocket needed. Built first (Phase 4) to validate the core loop and tune balance.
2. **Duel (1v1 real-time).** Two players, one shared pool, two prompts, simultaneous play.

## Match setup

1. Draw prompts. Practice: 1 random prompt. Duel: 2 random prompts, different ids.
2. Build the shared pool (see Architecture, "Pool builder"):
   - sample up to `membersPerPrompt` (30) universe players matching each prompt
   - fill the rest of the pool with decoys: universe players matching *neither* prompt
   - group(prompt) = pool ∩ prompt. A group can be slightly larger than 30 when sampled
     members of one prompt also match the other (natural overlap is allowed).
3. Validate the pair. Reject and redraw if the groups' Jaccard overlap > 0.3, or a group
   is outside [8, 60]. Simulation over all 378 starter-prompt pairs: group sizes 29–45
   (median 31), and 21 pairs are rejected for overlap.
4. Assign slots 1..N to each group in random order.
5. Start the timer.

## What each player sees

| Information | Owner of the group | Guesser of the group |
|---|---|---|
| Prompt title and description | Yes, from the start | Only after the match ends |
| Group member identities (all columns) | Yes, from the start | Only after the match ends |
| Group size N | Yes | Yes, from the start (the first guess reveals it anyway) |
| Guess SQL text, counts, reveals | Yes, for both players' guesses | Yes, for both players' guesses |
| The opponent's board of *your* group | Yes (it's their progress) | n/a |

In Duel, both players see each other's queries and each other's boards. Since your
opponent's board only shows *your* group, which you already know, nothing leaks.

## Guess rules

- The editor's first line is locked to `SELECT player_id`. The player writes the rest
  (`FROM ...`, `WHERE ...`, joins, `GROUP BY ... HAVING`, `UNION/INTERSECT/EXCEPT`, CTEs).
- The query runs against the **whole universe** (all football tables). The server
  intersects the result with the pool. Players never see raw result rows. They see only
  counts and reveals.
- Validation rejections and SQL errors do **not** consume a guess. Timeouts **do**
  (to discourage expensive queries).
- Only one guess in flight per player, with a minimum interval of 1.5 s between guesses.

## Feedback for a guess

```
Returned 41 · Hits 12 · False positives 29 · Missed 19 · Jaccard 0.20
```

- `returned` = |R|, where R = query result ∩ pool
- `hits` = |R ∩ G|, `falsePositives` = |R| − hits, `missed` = |G| − hits
- `jaccard` = hits / (|R| + |G| − hits)

## Reveal rules (the board)

The board for the opponent's group starts as N blank slots. For every hit member:

1. **Found:** the slot is marked found (it stays found).
2. **Column reveals:** for each `players` column referenced in a filtering clause
   (`WHERE`, `JOIN ... ON`, `HAVING`, including inside subqueries and CTEs), the member's
   actual value is revealed in that slot.
   - `player_id` is never revealed. `current_club_id` reveals the club *name*.
   - Values are the member's real values, so this is truthful even with `OR`/`NOT`.
   - Columns that only appear in `SELECT`/`ORDER BY` reveal nothing.
3. **Match chips:** the slot records which guess numbers it matched (e.g. `#3 #7`).
   Hovering a chip shows that guess's SQL. This is how conditions on other tables
   (transfers, appearances, games, clubs, aggregates) show up on the board without
   claiming anything untrue about an individual condition.

Missed members are never identified, only counted. False positives are never shown.

Example: guess `SELECT player_id FROM players WHERE height_in_cm >= 190 AND foot = 'left'`
hits slots 4 and 11 → both show `height_in_cm` and `foot` values plus chip `#5`.

## End conditions

1. **Win:** a guess's R equals the target group exactly. The match ends immediately.
   In Duel, if both players submit a winning guess almost simultaneously, the server's
   atomic compare-and-set decides: exactly one winner, the earlier commit. The other
   guess is still recorded and flagged as "arrived after match end".
2. **Out of guesses / time:** a player with no guesses left can only watch. When both
   are out of guesses, or the timer expires, the higher **best single-guess Jaccard**
   wins. Equal → draw.
3. **Forfeit:** explicit forfeit, or disconnected for more than 60 s → opponent wins.
4. Practice: win, or loss on budget/time. Score = guesses used and time taken.

At match end, both groups are fully revealed (names and all columns), along with both prompts.

## Tunable defaults

All live in `application.yml` under `hiddenxi.game.*`. They are starting points to tune
after playtesting (Phase 4).

| Key | Default | Notes |
|---|---|---|
| `poolSize` | 500 | ~18% of the universe |
| `membersPerPrompt` | 30 | sampled members per prompt |
| `groupSizeMin` / `groupSizeMax` | 8 / 60 | pair rejected otherwise |
| `maxGroupJaccard` | 0.3 | pair rejected above this |
| `guessBudget` | 25 | per player |
| `matchDuration` | 15 min | Duel and Practice |
| `minGuessInterval` | 1.5 s | per player |
| `statementTimeout` | 3 s | sandbox |
| `disconnectForfeitAfter` | 60 s | Duel |

## Screens (v1)

- **Home:** Practice, Create duel (get invite code), Join duel (enter code), nickname.
- **Game:** SQL editor (schema-aware autocomplete), guess log (both players in Duel),
  opponent-group board, your own group panel (Duel), opponent's board of your group
  (Duel), counters (guesses left, timer, best Jaccard), schema browser side panel,
  coverage notice.
- **Match summary:** winner and reason, both prompts, both full groups, each guess with
  its stats, and the canonical prompt SQL vs the winning query.

Coverage notice (shown in the schema browser and the match summary):

> Stats cover tracked European club competitions from 2012/13 to 2025/26: the top
> flights of 14 countries, their domestic cups and super cups where tracked, UEFA
> competitions (except the Conference League), and the Club World Cup. Player profiles
> are as of the 2025/26 season. International football appears only as caps and goals
> on player profiles.

## Non-goals for v1

Accounts with passwords (guest nicknames only until Phase 6), ranked matchmaking,
custom/user-written prompts, more than two players, mobile-specific UI, other sports
or data packs, caching.

## Decision log

| # | Decision | Why |
|---|---|---|
| 1 | Domain: football (Transfermarkt CC0 snapshot) | Rich many-to-many data (transfers, appearances), openly licensed |
| 2 | Feedback = overlap score + progressive board | Mastermind-like progress; board makes it visual |
| 3 | Reveal only columns used in filtering clauses | Prevents `SELECT *` from revealing everything |
| 4 | Guess budget + timer | Stops brute force and binary search |
| 5 | One shared pool per match, natural overlap allowed | Simpler; forced disjointness would leak "your members aren't theirs" |
| 6 | Every query auto-checked for a win | Simpler UX than a separate "submit answer" |
| 7 | Both players see each other's queries and boards | Adds race tension; no leak (see visibility table) |
| 8 | Queries must output `player_id`; editor prefix locked | Simple scoring contract |
| 9 | Prompts curated + random assignment; custom prompts later | Custom prompts could be unguessable (ID lists) |
| 10 | Queries run on the full universe; pool applied server-side | Replaces the earlier per-match scoped views. Same outcome for scoring, far simpler and safer (no runtime DDL or session variables), and enables prompts like "played alongside Messi" |
| 11 | Club football only for match data; international = profile attributes | National-team match data is too sparse (only the 2026 World Cup group stage and AFCON 2025) |
| 12 | Universe = active 2025/26 + ≥1 tracked top-flight appearance + (150+ apps or peak value ≥ €15M) | Includes young stars; excludes obscure players; consistent data |
| 13 | Players who moved to untracked leagues mid-career stay in if they still meet the rules (e.g. Messi, Ronaldo) | Their European careers are complete; stats framed as "European career" |
| 14 | No transfer-based "active" rescue for players last scraped before 2025 | Their profiles are stale; small gain, real complexity |
| 15 | No caching in v1 | Each guess is one cheap query; measure before optimizing |
| 16 | Build Practice before Duel | Validate fun and tune balance before investing in real-time |
| 17 | Commands via REST, server→client events via STOMP | Simpler than doing commands over WebSocket; same real-time feel |
