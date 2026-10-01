# 04 — Query Sandbox & Security

Players submit arbitrary SQL that the server executes. This is the most security-
sensitive part of the project, and the most interesting part to talk about in interviews.

## What we're protecting

The `football` schema contains **no secrets**: it's public data the player can browse
anyway. The secrets (pools, groups, prompts, other users) live in the `app` schema and in
server memory. So the sandbox must guarantee:

1. **Confidentiality:** user SQL can never read `app.*`, system catalogs, files, or settings.
2. **Integrity:** user SQL can never write, lock, or change anything (DDL, DML, `SET`, functions with side effects).
3. **Availability:** user SQL can't hog CPU, memory, disk, or connections.
4. **Game integrity:** the scoring contract can't be gamed (ID binary search, huge membership lists).

## Defense in depth

```
 [1] Request limits      length ≤ 2,000 chars; 1 in flight per seat; ≥ 1.5 s apart; budget
 [2] Parser allowlist    JSqlParser AST: only the constructs/tables/functions listed below (fail closed)
 [3] Deparse + wrap      execute the parser's re-serialized SQL, wrapped; never the raw text
 [4] DB role             hiddenxi_sandbox: SELECT on football.* only; read-only; role-level limits
 [5] Transaction limits  SET LOCAL statement_timeout / work_mem; READ ONLY; rollback always
 [6] Error hygiene       map SQLState → safe codes; never return stack traces or other internals
```

Every layer must hold even if the one before it fails. Example: if the parser misses a
dangerous function, the role still can't read `app.*`, and the timeout still kills
`pg_sleep`.

## [2] Validation rules (QueryValidator)

Parse with `CCJSqlParserUtil.parseStatements`. Anything that fails to parse is rejected
(`UNSUPPORTED_SYNTAX`) even if Postgres would accept it. Then walk the whole AST
(including subqueries, CTEs, set-operation branches, `EXISTS`/`IN` subqueries, `CASE`,
window definitions) with visitors that **allow** known constructs and reject everything
else. JSqlParser's `Validation` API (feature allowlists) can be used as an extra check,
but the custom allowlist visitor is authoritative.

**Statements**
- Exactly 1 statement. It must be a query: plain `SELECT`, set operations
  (`UNION [ALL]`, `INTERSECT`, `EXCEPT`), parenthesized selects, and non-recursive `WITH`.
- Rejected: everything else, plus `WITH RECURSIVE`, `SELECT ... INTO`, `FOR UPDATE/SHARE`,
  `TABLESAMPLE`, `LATERAL`, `VALUES` lists in `FROM`.

**Output contract**
- The top-level query (each branch of a set operation) must select exactly **one** item,
  and it must be a column reference whose column name is `player_id` (qualified, like
  `p.player_id`, is fine). Aliasing another expression as `player_id` is rejected.

**Tables**
- Only `players`, `clubs`, `competitions`, `games`, `appearances`, `transfers`, optionally
  qualified as `football.<table>`. CTE names defined in the same query are allowed.
- Any other identifier in `FROM`/`JOIN` is rejected (covers `app.*`, `pg_*`,
  `information_schema.*`, `public.*`), as are table functions such as `generate_series(...)`.

**Functions (allowlist, case-insensitive)**
- Aggregates: `count`, `sum`, `avg`, `min`, `max`, `bool_and`, `bool_or`
- Window: `row_number`, `rank`, `dense_rank`, `lag`, `lead` (with `OVER`)
- Scalar: `coalesce`, `nullif`, `greatest`, `least`, `lower`, `upper`, `length`,
  `char_length`, `substring`, `substr`, `position`, `trim`, `ltrim`, `rtrim`, `left`,
  `right`, `replace`, `concat`, `abs`, `round`, `floor`, `ceil`, `ceiling`, `mod`,
  `extract`, `date_part`, `date_trunc`, `age`, `make_date`
- `CAST`/`::` only to `integer`, `bigint`, `numeric`, `text`, `date`, `boolean`
- Everything else is rejected, explicitly including `now`, `current_date`,
  `current_timestamp`, `random`, `pg_sleep*`, `set_config`, `current_setting`, `pg_*`,
  `lo_*`, `dblink*`, `query_to_xml`, `xpath`, and any schema-qualified function.
  Non-deterministic functions are banned because the data is frozen; the UI suggests
  `age(DATE '2026-07-01', date_of_birth)` for ages.

**Expressions and operators**
- Allowed: comparisons, `AND/OR/NOT`, `IN` (list or subquery), `BETWEEN`, `LIKE`/`ILIKE`,
  `IS [NOT] NULL`, `EXISTS`, `CASE`, arithmetic, string concatenation `||`, literals
  (numbers, plain single-quoted strings, `DATE '...'`), `GROUP BY`, `HAVING`, `ORDER BY`,
  `LIMIT`, `OFFSET`, `DISTINCT`.
- Rejected: regex operators (`~`, `~*`, `SIMILAR TO`), `E'...'`/`U&'...'`/dollar-quoted
  strings, parameters/placeholders, array constructors.

**Game-integrity limits**
- No range predicates on ID columns: `<`, `<=`, `>`, `>=`, `BETWEEN` where either side is a
  column whose name is `player_id` or ends in `_id` → `ID_RANGE_NOT_ALLOWED`. Equality,
  `<>`, `IN`, and joins on IDs are fine. This blocks binary search over IDs.
- `IN (...)` literal lists: max 50 items (`IN_LIST_TOO_LONG`). This blocks big-list group testing.
- Structural caps: ≤ 5 subqueries/CTEs, ≤ 8 table references, nesting depth ≤ 4.

Validator output: either `Accepted(statement, referencedPlayersColumns)` or
`Rejected(code, message)`. `referencedPlayersColumns` is computed in the same walk: every
column in a `WHERE`/`ON`/`HAVING` clause that resolves (via aliases and the catalog) to
`players`. Unqualified columns resolve to `players` only if `players` is in scope and is
the only in-scope table that has the column.

## [3] Rewrite

```java
String inner = acceptedStatement.toString();      // JSqlParser deparse, not the user's raw text
String sql = "SELECT DISTINCT q.player_id FROM (" + inner + ") AS q LIMIT 5001";
```

Executing the deparsed AST guarantees that what runs is what was validated. That closes
parser/database differentials such as comment tricks or quoting edge cases. Run the
prompt library and the "accept" corpus through deparse-and-execute in tests to confirm
deparse doesn't change their meaning.

## [4] Database role (Docker init script, run as superuser)

```sql
CREATE ROLE hiddenxi_sandbox LOGIN PASSWORD :'sandbox_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 10;
GRANT CONNECT ON DATABASE hiddenxi TO hiddenxi_sandbox;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER ROLE hiddenxi_sandbox SET default_transaction_read_only = on;
ALTER ROLE hiddenxi_sandbox SET statement_timeout = '3s';
ALTER ROLE hiddenxi_sandbox SET idle_in_transaction_session_timeout = '5s';
ALTER ROLE hiddenxi_sandbox SET search_path = football;
ALTER ROLE hiddenxi_sandbox SET work_mem = '16MB';
ALTER ROLE hiddenxi_sandbox SET temp_file_limit = '64MB';     -- superuser-only parameter
-- after Flyway creates schema football (in a migration run by the owner):
GRANT USAGE ON SCHEMA football TO hiddenxi_sandbox;
GRANT SELECT ON ALL TABLES IN SCHEMA football TO hiddenxi_sandbox;
-- no grants at all on schema app
```

System catalogs stay readable by `PUBLIC` in Postgres (that can't easily be revoked),
which is one reason the parser's table allowlist matters. Nothing secret is in the
catalogs anyway, since game state is data in `app`, which the role can't read.

## [5] Execution (SandboxExecutor)

```
conn from sandbox pool (readOnly=true)
BEGIN; SET TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '<hiddenxi.game.statementTimeout>';
run wrapped query; read ints into a Set (max 5001; if 5001 rows → TOO_MANY_ROWS, not possible with a 2,837-player universe but kept as a guard)
ROLLBACK (always)
```

## [6] Error mapping

| Condition | Code | Consumes a guess? | Message to user |
|---|---|---|---|
| Validator rejection | rule-specific (`TABLE_NOT_ALLOWED`, `FUNCTION_NOT_ALLOWED`, …) | No | Explain the rule, naming the offending table/function |
| Parse failure | `UNSUPPORTED_SYNTAX` | No | "This SQL isn't supported. Check syntax or simplify." |
| SQLState class 42 (undefined column, ambiguous column, grouping error…) / class 22 (data exception) | `SQL_ERROR` | No | Postgres message text only (no position/hint/internal query). The football data is public, so this is safe |
| SQLState 57014 (statement timeout) | `TIMEOUT` | **Yes** | "Query took longer than 3 s." |
| Anything else | `INTERNAL` | No | Generic message; log the details server-side |

## Security test corpus (must be automated)

Store as `backend/src/test/resources/sandbox/corpus.yml` (`sql`, `expect: ACCEPT | <code>`),
used by both validator unit tests and executor integration tests. Starter set:

| # | SQL (after the locked `SELECT player_id`) | Expect |
|---|---|---|
| 1 | `FROM players WHERE foot = 'left'` | ACCEPT |
| 2 | `FROM appearances GROUP BY player_id HAVING SUM(goals) >= 100` | ACCEPT |
| 3 | `FROM players p JOIN clubs c ON c.club_id = p.current_club_id WHERE c.name = 'Arsenal FC'` | ACCEPT |
| 4 | `FROM players WHERE foot='left' INTERSECT SELECT player_id FROM players WHERE position='Goalkeeper'` | ACCEPT |
| 5 | `FROM players WHERE age(DATE '2026-07-01', date_of_birth) > INTERVAL '30 years'` | `UNSUPPORTED_SYNTAX` or ACCEPT. Decide; if rejected, document the `extract(year from age(...))` form |
| 6 | `FROM players; DROP TABLE football.players` | `MULTIPLE_STATEMENTS` |
| 7 | `FROM app.matches` | `TABLE_NOT_ALLOWED` |
| 8 | `FROM pg_catalog.pg_user` | `TABLE_NOT_ALLOWED` |
| 9 | `FROM information_schema.tables` | `TABLE_NOT_ALLOWED` |
| 10 | `FROM players WHERE pg_sleep(10) IS NOT NULL` | `FUNCTION_NOT_ALLOWED` |
| 11 | `FROM players WHERE set_config('search_path','app',true) IS NOT NULL` | `FUNCTION_NOT_ALLOWED` |
| 12 | `FROM players WHERE current_setting('server_version') <> ''` | `FUNCTION_NOT_ALLOWED` |
| 13 | `FROM generate_series(1, 1000000000) AS player_id` | `TABLE_NOT_ALLOWED` |
| 14 | `FROM players WHERE player_id < 50000` | `ID_RANGE_NOT_ALLOWED` |
| 15 | `FROM players WHERE player_id BETWEEN 1 AND 99999` | `ID_RANGE_NOT_ALLOWED` |
| 16 | `FROM players WHERE name IN (<60 names>)` | `IN_LIST_TOO_LONG` |
| 17 | `, name FROM players` | `OUTPUT_CONTRACT` |
| 18 | `FROM players FOR UPDATE` | `UNSUPPORTED_CONSTRUCT` |
| 19 | `FROM (WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r) SELECT n AS player_id FROM r) x` | `UNSUPPORTED_CONSTRUCT` |
| 20 | `FROM players WHERE name ~ '^A'` | `OPERATOR_NOT_ALLOWED` |
| 21 | `FROM players WHERE name = E'\x41'` | `UNSUPPORTED_SYNTAX` |
| 22 | `FROM players WHERE now() > date_of_birth` | `FUNCTION_NOT_ALLOWED` |
| 23 | `FROM players /* comment */ WHERE foot = 'left' -- trailing` | ACCEPT (comments dropped by deparse) |
| 24 | `FROM appearances a, appearances b, appearances c` | ACCEPT by validator → `TIMEOUT` at execution (consumes a guess) |
| 25 | `FROM players WHERE lo_import('/etc/passwd') > 0` | `FUNCTION_NOT_ALLOWED` |
| 26 | `FROM football.players WHERE foot = 'both'` | ACCEPT |
| 27 | `FROM players WHERE query_to_xml('select * from app.users', true, true, '') IS NOT NULL` | `FUNCTION_NOT_ALLOWED` |
| 28 | `FROM players INTO TEMP t` | `UNSUPPORTED_CONSTRUCT` |
| 29 | `FROM players WHERE foot = $1` | `UNSUPPORTED_SYNTAX` |
| 30 | `FROM players WHERE CAST(name AS regclass) IS NOT NULL` | `CAST_NOT_ALLOWED` |

Add a case for every bug found. Also run each `ACCEPT` case end-to-end as the sandbox
role, and each rejected case directly as the sandbox role (bypassing the validator) to
prove that layers [4]–[5] alone still block or contain it.

## Game-integrity rules outside SQL

- Hidden-group player IDs never leave the server before the match ends. Slots are random
  per match. `GuessEvaluated` contains slots and revealed values only.
- `GET /api/matches/{id}` filters by caller: own group yes, target group no.
- Reveal values are read via the owner DataSource from the in-memory universe map, never
  by running extra user-influenced SQL.
- Rate limits and budgets are enforced server-side. Client-side checks are only UX.
