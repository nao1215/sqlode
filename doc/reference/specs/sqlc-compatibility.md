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
| `runtime` | Implemented | `raw`, `native` (`based` is rejected) |
| `emit_exact_table_names` | Implemented | Use table names as-is instead of singularising |
| `emit_sql_as_comment` | Implemented | Include SQL text as a comment in generated code |
| `omit_unused_models` | Implemented | Only emit models referenced by generated queries |
| `vendor_runtime` | Implemented | Copy runtime module into the output directory |
| `strict_views` | Implemented | Promote view resolution warnings to errors |
| `overrides.types` | Implemented | Map DB types to Gleam types (custom types must be transparent aliases, not opaque) |
| `overrides.renames` | Implemented | Rename columns in result types |

### Not yet implemented options

| Option | Status |
|--------|--------|
| `query_parameter_limit` | Not implemented |
| `database` | Not implemented (live DB analysis) |
| `analyzer` | Not implemented |

These options are **rejected** with an error if present in the config file. sqlode prefers early errors over silently ignoring unsupported configuration. Remove these fields from your config to proceed.

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

Batch annotations and `:copyfrom` are also implemented:

- `:batchone` — batch variant of `:one`
- `:batchmany` — batch variant of `:many`
- `:batchexec` — batch variant of `:exec`
- `:copyfrom` — bulk insert

`:execresult` is available with `raw` runtime only. It is rejected with `native` runtime.

## Macros and parameter naming

### Implemented macros

| Macro | Status | Notes |
|-------|--------|-------|
| `sqlode.arg(name)` | Implemented | Names a parameter |
| `sqlode.narg(name)` | Implemented | Names a nullable parameter |
| `sqlode.slice(name)` | Implemented | Expands to list parameter |
| `sqlode.embed(table)` | Implemented | Flattens all table columns into result |

The `sqlc.*` prefix is also accepted for backward compatibility.

### Compatibility notes

- `sqlode.arg` and `sqlode.narg` are expanded by the query parser into
  engine-agnostic markers (`__sqlode_param_N__`). These are substituted
  with engine-specific placeholders (`$N` for PostgreSQL, `?` for SQLite)
  by `runtime.prepare` at runtime.
- `sqlode.embed` flattens all columns from the embedded table into the
  result type. **Note:** This differs from sqlc's Go behavior which
  produces nested structs. Gleam does not have implicit struct embedding.
- `sqlode.slice` generates a `List(T)` parameter type.
- `@name` shorthand is supported on PostgreSQL and SQLite (not MySQL).

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
| PostgreSQL ENUM | Generated custom type |

Nullable columns (without `NOT NULL`) are wrapped in `Option(T)`.

Type overrides allow remapping DB types to different Gleam types.

### Implemented type extensions

- PostgreSQL arrays (`TEXT ARRAY`, `BIGINT ARRAY`, etc.) — mapped to `List(T)` / `Option(List(T))`
- Arrays are only supported with the PostgreSQL engine; SQLite and MySQL reject array parameters at generation time

### Not yet implemented

- MySQL `ENUM` / `SET`
- SQLite affinity-based typing edge cases

## Sources

- sqlc configuration:
  https://docs.sqlc.dev/en/stable/reference/config.html
- sqlc query annotations:
  https://docs.sqlc.dev/en/stable/reference/query-annotations.html
- sqlc macros:
  https://docs.sqlc.dev/en/stable/reference/macros.html
