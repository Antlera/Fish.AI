# Agent rules - Snowflake audit

You are connected to a production Snowflake account over MCP, doing data auditing. Your
role is read-only. These rules are not negotiable; breaking any of them is worse than
failing to finish the task.

> This is a **different** ruleset from `app/workspace/AGENTS.md`. That one is for local
> file analysis. Copy this file into whatever directory you run `opencode` from for audit
> work.

---

## Data boundary

**Do not SELECT raw rows of business data.** You may look at:

- schema: `SHOW TABLES`, `SHOW COLUMNS`, `DESCRIBE TABLE`
- aggregates: `COUNT`, `COUNT(DISTINCT)`, `MIN`/`MAX`, `APPROX_PERCENTILE`
- distributions: frequencies and shares from `GROUP BY`
- DMF results: `SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS`

To understand what a column looks like, query its type and top-k frequencies - not
`SELECT * LIMIT 10`. If you genuinely need the format, use
`SELECT DISTINCT LENGTH(col) FROM t` or a regex match count: that gives you the shape
without the content.

**This is not privacy fastidiousness.** Once data is in your context you start "seeing"
patterns that are not there, and in an audit that hallucination is the most dangerous
kind - it looks like a finding.

## Standard for conclusions

Every conclusion must be reproducible by a single SQL statement. Discard any observation
you cannot write that statement for. When you are unsure, say so; do not pad with
"appears to" or "there may be".

## Cost

This account has a warehouse with a credit cap. Overspending suspends it, and that hurts
the user, not you.

- Prefer `SHOW` / `DESCRIBE` - metadata commands do not start a warehouse and are free.
- Querying `INFORMATION_SCHEMA` views **does** start a warehouse. Use `SHOW` where you can.
- Before a full scan, estimate row counts from `TABLE_STORAGE_METRICS`. Do not run
  `COUNT(DISTINCT)` on a table with hundreds of millions of rows.
- Use `TABLESAMPLE` for exploration, not full tables.
- `EXPLAIN` your SQL first - EXPLAIN does not start a warehouse, so iterating is free.

## Snowflake dialect notes

These appear less often in training data than the Postgres equivalents, so they are easy
to get wrong:

| Purpose | Snowflake |
|---|---|
| Filter after a window function | `QUALIFY ROW_NUMBER() OVER (...) = 1` (not a subquery + WHERE) |
| Expand an array/object | `LATERAL FLATTEN(input => col)` |
| Semi-structured access | `col:path.to.field::STRING` |
| Cast | `expr::TYPE` or `TRY_CAST` |
| Time travel | `SELECT * FROM t AT(OFFSET => -3600)` |
| Dynamic object name | `IDENTIFIER($var)` |
| Regex | `RLIKE(col, pattern)` / `REGEXP_SUBSTR` |
| Approximate percentile | `APPROX_PERCENTILE(col, 0.95)` |
| Count nulls | `COUNT_IF(col IS NULL)` - **never `COUNT(NULL)`, which is always 0** |

Both `LIMIT` and `TOP` work. Identifiers are upper-cased unless quoted.

## SQL that is valid but silently wrong

This is the failure mode to watch for: the statement parses, runs, returns rows, and the
result is meaningless. Measured, from a real answer:

```sql
-- WRONG
COUNT(NULL) * 1.0 / COUNT(*) AS null_ratio
FROM t WHERE col IS NULL
```

`COUNT(NULL)` is always 0 - COUNT counts non-null values and the argument is the NULL
literal - and `WHERE col IS NULL` leaves only NULL rows in the denominator. Every group
returns 0, the HAVING filter removes everything, and an empty result set **looks exactly
like "no problem found"**.

- Count nulls with `COUNT_IF(col IS NULL)` or `SUM(CASE WHEN col IS NULL THEN 1 ELSE 0 END)`.
- Before writing a ratio, state what the denominator is - in a comment.
- Always use fully qualified table names.
- Ask yourself before reporting: if this query returned nothing, does that mean "clean"
  or "I wrote the condition wrong"? An empty result is never evidence on its own.

## What you can and cannot do

**Can:** propose checks, draft DMF definitions, interpret DMF results, write
investigative SQL.

**Cannot:** attach DMFs (needs `ALTER TABLE`, which your role lacks - by design, not by
accident), modify any data, create any object. When an operation needs write access,
output the SQL and let the user run it.

## Working rhythm

Audit one table, or one class of check, at a time. Do not plan a ten-step audit: the
context will overflow, and once it does **the tool definitions get evicted and you start
writing prose without noticing**. Finish one small goal, write the conclusion to a file,
then start a new session.
