# Configuration

Without `--config`, sqlode looks in the current directory for `sqlode.yaml`, `sqlode.yml`, `sqlc.yaml`, `sqlc.yml` or `sqlc.json`, and stops if it finds more than one.

```yaml
version: "2"
sql:
  - name: "app"
    schema: "db/schema.sql"
    queries: "db/query.sql"
    engine: "postgresql"
    gen:
      gleam:
        out: "src/db"
        runtime: "native"
```

`schema` and `queries` take a path, a list of paths or a directory of `.sql` files. The schema can be a snapshot or a migration history. `name` labels the block in messages.

## gen.gleam keys

| Key | Default | Effect |
|---|---|---|
| `out` | required | Output directory |
| `runtime` | `raw` | `native` also writes an adapter for pog, sqlight or shork |
| `type_mapping` | `string` | `rich` or `strong` for date, time, UUID and JSON types (below) |
| `vendor_runtime` | `false` | Copies `sqlode/runtime` into `out` so sqlode can be a dev dependency |
| `strict_views` | `true` | `false` warns about view columns it cannot resolve and drops them |
| `emit_sql_as_comment` | `false` | Adds each query's SQL as a comment on its adapter function |
| `emit_exact_table_names` | `false` | `authors` becomes `Authors` instead of `Author` |
| `omit_unused_models` | `false` | Leaves out table records that no query uses |
| `query_parameter_limit` | none | `verify` reports queries with more inferred parameters |

## Types

| SQL type | Gleam type |
|---|---|
| INT, INTEGER, SMALLINT, BIGINT, SERIAL, BIGSERIAL | `Int` |
| FLOAT, DOUBLE, REAL, NUMERIC, DECIMAL, MONEY | `Float` |
| BOOLEAN, BOOL | `Bool` |
| TEXT, VARCHAR, CHAR, and other text-like types | `String` |
| BYTEA, BLOB, BINARY | `BitArray` |
| TIMESTAMP, DATETIME, DATE, TIME, TIMETZ, INTERVAL, UUID, JSON, JSONB | `String` |
| CITEXT, INET, CIDR, MACADDR, XML, BIT, TSVECTOR, TSQUERY, geometric types | `String` |
| `TYPE[]`, `TYPE ARRAY` | `List(TYPE)` |
| PostgreSQL `CREATE TYPE ... AS ENUM`, MySQL `ENUM` and `SET` | A custom type with `to_string` and `from_string` functions |

A column without `NOT NULL` becomes `Option(T)`.

`type_mapping: "rich"` turns the date, time, UUID and JSON types into `String` aliases such as `SqlUuid`, which document a signature without a compiler check. `strong` makes them wrapper types such as `SqlUuid(String)` with a `sql_uuid_to_string` function, so a UUID and a `String` cannot be mixed up.

## Overrides and renames

```yaml
sql:
  - schema: "db/schema.sql"
    queries: "db/query.sql"
    engine: "postgresql"
    gen:
      gleam:
        out: "src/db"
    overrides:
      types:
        - db_type: "uuid"
          gleam_type: "String"
        - column: "users.id"
          gleam_type: "myapp/types.UserId"
          encode: "user_id_to_int"
          decode: "int_to_user_id"
      renames:
        - table: "authors"
          column: "bio"
          rename_to: "biography"
```

`db_type` applies to every column of that type, and `column` to one column. A `column` override wins.

A custom `gleam_type` without `encode` and `decode` must be a type alias of the underlying type. For any other type, give both functions; sqlode looks them up in the module of `gleam_type`, so the example calls `types.user_id_to_int`.

## What sqlode understands

Schema statements: `CREATE TABLE`, `CREATE VIEW`, `CREATE TYPE ... AS ENUM`, `ALTER TABLE` (add, drop and rename columns, rename the table, change a column's type and nullability), and `DROP TABLE`, `DROP VIEW`, `DROP TYPE`. PostgreSQL and SQLite skip other statements; MySQL stops with SQD2004.

Parameter types are inferred from:

- the column in `INSERT ... VALUES`, `SET col =`, comparisons, `IN` lists and `ANY(...)`
- the numeric column in arithmetic such as `visits + $1`
- `LIMIT` and `OFFSET`, which are `Int`
- a cast, `$1::int` or `CAST($1 AS INTEGER)`

Anywhere else, generation stops with SQD4003. Add a cast.

Result columns are resolved through joins, `RETURNING`, CTEs and views.
