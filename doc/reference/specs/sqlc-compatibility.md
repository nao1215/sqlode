# sqlc Compatibility Target

## Goal

`sqlode` should feel familiar to existing `sqlc` users:

- same mental model: schema files + query files + generated typed API
- same query naming convention
- same primary engines: PostgreSQL, MySQL, SQLite
- same default config shape where practical

The compatibility target is sqlc configuration version 2.

## Config surface

The baseline config shape matches sqlc v2:

```yaml
version: "2"
sql:
  - schema: "db/schema.sql"
    queries: "db/query.sql"
    engine: "postgresql"
    gen:
      gleam:
        package: "db"
        out: "src/db"
        runtime: "raw"
    overrides:
      types:
        - db_type: "uuid"
          gleam_type: "String"
      renames:
        - table: "authors"
          column: "bio"
          rename_to: "biography"
```

### Implemented `gen.gleam` options

| Option | Status | Notes |
|--------|--------|-------|
| `package` | Implemented | Package name for imports |
| `out` | Implemented | Output directory |
| `runtime` | Implemented | `raw`, `based`, `native` |
| `overrides.types` | Implemented | Map DB types to Gleam types |
| `overrides.renames` | Implemented | Rename columns in result types |

### Not yet implemented options

| Option | Status |
|--------|--------|
| `emit_exact_table_names` | Not implemented |
| `emit_sql_as_comment` | Not implemented |
| `query_parameter_limit` | Not implemented |
| `database` | Not implemented (live DB analysis) |
| `analyzer` | Not implemented |

These options are accepted in the config model but have no effect.

## Query annotations

The required naming format matches sqlc:

```sql
-- name: GetAuthor :one
SELECT * FROM authors WHERE id = $1;
```

### Implemented annotations

All core sqlc annotations are implemented:

- `:one` — returns at most one row
- `:many` — returns zero or more rows
- `:exec` — returns nothing
- `:execresult` — returns the execution result
- `:execrows` — returns affected row count
- `:execlastid` — returns last inserted ID

### Not implemented annotations

Batch annotations are not yet supported:

- `:batchexec`
- `:batchmany`
- `:batchone`
- `:copyfrom`

## Macros and parameter naming

### Implemented macros

| Macro | Status | Notes |
|-------|--------|-------|
| `sqlc.arg(name)` | Implemented | Names a parameter |
| `sqlc.narg(name)` | Implemented | Names a nullable parameter |
| `sqlc.slice(name)` | Implemented | Expands to list parameter |
| `sqlc.embed(table)` | Implemented | Flattens all table columns into result |

### Compatibility notes

- `sqlc.arg` and `sqlc.narg` are expanded by the query parser into
  engine-appropriate placeholders (`$N` for PostgreSQL, `?` for MySQL,
  `?N` for SQLite).
- `sqlc.embed` flattens all columns from the embedded table into the
  result type. **Note:** This differs from sqlc's Go behavior which
  produces nested structs. Gleam does not have implicit struct embedding.
- `sqlc.slice` generates a `List(T)` parameter type.
- `@name` shorthand is **not yet implemented**.

## Type mapping

### Implemented type families

| SQL Type | Gleam Type |
|----------|-----------|
| INT, INTEGER, BIGINT, SERIAL, BIGSERIAL, SMALLINT | Int |
| FLOAT, DOUBLE, REAL, NUMERIC, DECIMAL | Float |
| BOOLEAN, BOOL | Bool |
| TEXT, VARCHAR, CHAR | String |
| BYTEA, BLOB, BINARY | BitArray |
| TIMESTAMP, DATETIME | String |
| DATE | String |
| TIME, TIMETZ | String |
| UUID | String |
| JSON, JSONB | String |
| PostgreSQL ENUM | String |

Nullable columns (without `NOT NULL`) are wrapped in `Option(T)`.

Type overrides allow remapping DB types to different Gleam types.

### Not yet implemented

- PostgreSQL arrays
- MySQL `ENUM` / `SET`
- SQLite affinity-based typing edge cases

## Sources

- sqlc configuration:
  https://docs.sqlc.dev/en/stable/reference/config.html
- sqlc query annotations:
  https://docs.sqlc.dev/en/stable/reference/query-annotations.html
- sqlc macros:
  https://docs.sqlc.dev/en/stable/reference/macros.html
