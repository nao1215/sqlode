# sqlode

[![Hex](https://img.shields.io/hexpm/v/sqlode)](https://hex.pm/packages/sqlode)
[![Hex Downloads](https://img.shields.io/hexpm/dt/sqlode)](https://hex.pm/packages/sqlode)
[![CI](https://github.com/nao1215/sqlode/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/sqlode/actions/workflows/ci.yml)
[![license](https://img.shields.io/github/license/nao1215/sqlode)](./LICENSE)

sqlode reads SQL schema and query files, then generates typed Gleam code. The workflow follows [sqlc](https://sqlc.dev/) conventions: write SQL, run the generator, get type-safe functions.

Supported engines: PostgreSQL, MySQL (parsing only), SQLite.

## Getting started

### Install

sqlode ships as an Erlang escript. Every install path therefore needs an Erlang/OTP runtime on the host (`escript` on PATH). The easiest way to cover both downloading the escript and detecting a missing runtime is the one-line installer:

#### Option A: One-line install (recommended)

```console
curl -fsSL https://raw.githubusercontent.com/nao1215/sqlode/main/scripts/install.sh | sh
```

Prefer to inspect the script before executing it? Download it first, read it, then run it:

```console
curl -fsSL -o install.sh https://raw.githubusercontent.com/nao1215/sqlode/main/scripts/install.sh
sh install.sh
```

The installer writes the latest release's escript to `$HOME/.local/bin/sqlode`, makes it executable, and warns if Erlang/OTP is missing (with a per-distro install hint).

Environment variables:

- `SQLODE_VERSION=v0.1.0` — pin a specific release tag instead of `latest`.
- `SQLODE_INSTALL_DIR=/path/to/bin` — install into a different directory. System paths such as `/usr/local/bin` require elevated privileges, e.g. `curl -fsSL ... | sudo SQLODE_INSTALL_DIR=/usr/local/bin sh`.

If `$HOME/.local/bin` is not on your `PATH`, add it to your shell config:

```console
export PATH="$HOME/.local/bin:$PATH"
```

You still need sqlode as a project dependency because generated code imports `sqlode/runtime`:

```console
gleam add sqlode
```

#### Option B: Manual escript download

Download the pre-built escript from [GitHub Releases](https://github.com/nao1215/sqlode/releases) and place it on your `PATH`:

```console
chmod +x sqlode
./sqlode generate --config=sqlode.yaml
```

#### Option C: Run via Gleam

If you already have a Gleam project, you can invoke the CLI through `gleam run` without downloading a separate binary:

```console
gleam add sqlode
gleam run -m sqlode -- generate
```

### Initialize config

```console
# standalone CLI
sqlode init

# or via Gleam
gleam run -m sqlode -- init
```

This creates `sqlode.yaml` along with stub files `db/schema.sql` and `db/query.sql`:

```yaml
version: "2"
sql:
  - schema: "db/schema.sql"
    queries: "db/query.sql"
    engine: "postgresql"
    gen:
      gleam:
        out: "src/db"
        runtime: "raw"
```

`schema` and `queries` accept either a single file path, a list of file paths, or a directory path. When given a directory, sqlode auto-discovers every `.sql` file inside it. An optional `name` field can be set on each `sql` block for diagnostics when multiple blocks are configured.

### Write SQL

Schema (`db/schema.sql`):

```sql
CREATE TABLE authors (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  bio TEXT,
  created_at TIMESTAMP NOT NULL
);
```

Queries (`db/query.sql`):

```sql
-- name: GetAuthor :one
SELECT id, name, bio
FROM authors
WHERE id = $1;

-- name: ListAuthors :many
SELECT id, name
FROM authors
ORDER BY name;

-- name: CreateAuthor :exec
INSERT INTO authors (name, bio)
VALUES (sqlode.arg(author_name), sqlode.narg(bio));
```

### Generate

```console
# standalone CLI
sqlode generate

# or via Gleam
gleam run -m sqlode -- generate
```

This produces `params.gleam` and `queries.gleam` in the configured output directory. `models.gleam` is also generated when the schema defines tables or when at least one query uses `:one` or `:many` and returns result columns.

## Generated code

### params.gleam

```gleam
pub type GetAuthorParams {
  GetAuthorParams(id: Int)
}

pub fn get_author_values(params: GetAuthorParams) -> List(Value) {
  [runtime.int(params.id)]
}

pub type CreateAuthorParams {
  CreateAuthorParams(author_name: String, bio: Option(String))
}
```

### models.gleam

sqlode generates reusable record types for each table in the schema, plus per-query row types for queries that return results. When a query's result columns exactly match a table (same columns, types, nullability, and order), a type alias is emitted instead of a duplicate record type.

```gleam
// Table record type (singularized) — reusable across queries
pub type Author {
  Author(id: Int, name: String, bio: Option(String), created_at: String)
}

// Exact table match — alias instead of duplicate
pub type GetAuthorRow =
  Author

// Partial match — separate row type
pub type ListAuthorsRow {
  ListAuthorsRow(id: Int, name: String)
}
```

### queries.gleam

Each query function returns a `RawQuery(p)`:

`QueryInfo` and `all()` list all queries in a module without type parameters.

```gleam
pub type QueryInfo {
  QueryInfo(name: String, sql: String, command: runtime.QueryCommand, param_count: Int)
}

pub fn all() -> List(QueryInfo) { ... }

pub fn get_author() -> runtime.RawQuery(params.GetAuthorParams) { ... }
pub fn list_authors() -> runtime.RawQuery(Nil) { ... }
pub fn create_author() -> runtime.RawQuery(params.CreateAuthorParams) { ... }
```

Usage example — the compiler ensures you pass the right params to the right query:

```gleam
let q = queries.get_author()
let values = q.encode(params.GetAuthorParams(id: 1))
// q.sql, q.command, and values are now tied together
```

For queries using `sqlode.slice()`, use `runtime.prepare` to expand slice placeholders and encode parameters in one call:

```gleam
let q = queries.get_authors_by_ids()
let #(sql, values) = runtime.prepare(
  q,
  params.GetAuthorsByIdsParams(ids: [1, 2, 3]),
  "$",  // "$" for PostgreSQL, "?" for SQLite
)
// sql has expanded placeholders: "... WHERE id IN ($1, $2, $3)"
// values is the flattened parameter list
```

## Runtime modes

The `runtime` option controls what code sqlode generates and what dependencies your project needs.

| Mode | Generated files | DB driver needed | Use case |
|------|----------------|-----------------|----------|
| `raw` | queries, params, models | No | You handle database interaction yourself |
| `native` | queries, params, models, adapter | Yes (pog/sqlight) | Full adapter with parameter binding and result decoding |

In all modes, sqlode must be a dependency (not just a dev-dependency) because the generated code imports `sqlode/runtime`. The `native` mode additionally requires a database driver package:

```console
gleam add sqlode
gleam add pog       # for PostgreSQL with native runtime
gleam add sqlight   # for SQLite with native runtime
```

### Self-contained generation (`vendor_runtime`)

Setting `gen.gleam.vendor_runtime: true` asks sqlode to copy the
`sqlode/runtime` module into the output directory as `runtime.gleam`
and rewrite the generated imports to point at the local copy. The
generated package no longer needs sqlode as a runtime dependency,
only as a dev dependency (the tool you invoke with `sqlode generate`).
Native adapters still need their driver package (`pog` / `sqlight`).

```yaml
gen:
  gleam:
    out: "src/db"
    runtime: "raw"
    vendor_runtime: true
```

Trade-offs: shared-runtime code is smaller and auto-updates with
`gleam update sqlode`; vendored code is self-contained at the cost of
re-running `sqlode generate` to pick up runtime changes.

## Adapter generation

When `runtime` is set to `native`, sqlode generates adapter modules that wrap [pog](https://hexdocs.pm/pog/) (PostgreSQL) or [sqlight](https://hexdocs.pm/sqlight/) (SQLite).

MySQL adapter generation is not available. MySQL works with `runtime: "raw"` only; `runtime: "native"` is rejected at config validation.

```yaml
gen:
  gleam:
    out: "src/db"
    runtime: "native"
```

The adapter provides functions that handle parameter binding, query execution, and result decoding:

```gleam
// pog_adapter.gleam (generated)
pub fn get_author(db: pog.Connection, p: params.GetAuthorParams)
  -> Result(Option(models.GetAuthorRow), pog.QueryError)
```

### Using the generated adapter

#### SQLite example

```gleam
import db/params
import db/sqlight_adapter
import gleam/io
import gleam/option
import sqlight

pub fn main() {
  let assert Ok(db) = sqlight.open(":memory:")

  // Create table
  let assert Ok(_) = sqlight.exec(
    "CREATE TABLE authors (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      bio TEXT
    );",
    db,
  )

  // :exec — returns Result(Nil, sqlight.Error)
  let assert Ok(_) = sqlight_adapter.create_author(
    db,
    params.CreateAuthorParams(
      author_name: "Alice",
      bio: option.Some("Author bio"),
    ),
  )

  // :one — returns Result(Option(Row), sqlight.Error)
  let assert Ok(option.Some(author)) = sqlight_adapter.get_author(
    db,
    params.GetAuthorParams(id: 1),
  )
  io.debug(author.name)  // "Alice"

  // :many — returns Result(List(Row), sqlight.Error)
  let assert Ok(authors) = sqlight_adapter.list_authors(db)
  io.debug(authors)  // [ListAuthorsRow(id: 1, name: "Alice")]
}
```

#### PostgreSQL example

```gleam
import db/params
import db/pog_adapter
import gleam/io
import gleam/option
import pog

pub fn main() {
  let db = pog.default_config()
    |> pog.host("localhost")
    |> pog.database("mydb")
    |> pog.connect()

  // :one — returns Result(Option(Row), pog.QueryError)
  let assert Ok(option.Some(author)) = pog_adapter.get_author(
    db,
    params.GetAuthorParams(id: 1),
  )
  io.debug(author.name)

  // :many — returns Result(List(Row), pog.QueryError)
  let assert Ok(authors) = pog_adapter.list_authors(db)
  io.debug(authors)
}
```

#### Return types by annotation

| Annotation | sqlight return type | pog return type |
|---|---|---|
| `:one` | `Result(Option(Row), sqlight.Error)` | `Result(Option(Row), pog.QueryError)` |
| `:many` | `Result(List(Row), sqlight.Error)` | `Result(List(Row), pog.QueryError)` |
| `:exec` | `Result(Nil, sqlight.Error)` | `Result(Nil, pog.QueryError)` |
| `:execrows` | `Result(Int, sqlight.Error)` | `Result(Int, pog.QueryError)` |
| `:execlastid` | `Result(Int, sqlight.Error)` | `Result(Int, pog.QueryError)` |

`:batchone`, `:batchmany`, `:batchexec`, and `:copyfrom` are not yet implemented. Using them currently fails generation with an unsupported-annotation error. See the Planned annotations section below.

`:execresult` is available with `raw` runtime only. It is rejected with `native` runtime because its semantics are not distinct from `:execrows`.

## Query annotations

| Annotation | Description |
|---|---|
| `:one` | Returns at most one row |
| `:many` | Returns zero or more rows |
| `:exec` | Returns nothing |
| `:execresult` | Returns the execution result (raw runtime only) |
| `:execrows` | Returns the number of affected rows |
| `:execlastid` | Returns the last inserted ID |

### Planned annotations

The following annotations are reserved for future work. Using any of them currently fails generation with an unsupported-annotation error.

| Annotation | Planned behavior |
|---|---|
| `:batchone` | Batch variant of `:one` |
| `:batchmany` | Batch variant of `:many` |
| `:batchexec` | Batch variant of `:exec` |
| `:copyfrom` | Bulk insert |

## Query macros

| Macro | Description |
|---|---|
| `sqlode.arg(name)` | Names a parameter |
| `sqlode.narg(name)` | Names a nullable parameter |
| `sqlode.slice(name)` | Expands to a list parameter for IN clauses |
| `sqlode.embed(table)` | Embeds all columns of a table into the result |
| `@name` | Shorthand for `sqlode.arg(name)` |

### Skipping a query

Prefix a query block with `-- sqlode:skip` to exclude it from generation. Useful for queries that rely on syntax sqlode cannot yet parse:

```sql
-- sqlode:skip
-- name: ComplexQuery :many
SELECT ...;
```

### sqlode.slice example

```sql
-- name: GetAuthorsByIds :many
SELECT id, name FROM authors
WHERE id IN (sqlode.slice(ids));
```

Generates a parameter with type `List(Int)`:

```gleam
pub type GetAuthorsByIdsParams {
  GetAuthorsByIdsParams(ids: List(Int))
}
```

### sqlode.embed example

```sql
-- name: GetBookWithAuthor :one
SELECT sqlode.embed(authors), books.title
FROM books
JOIN authors ON books.author_id = authors.id
WHERE books.id = $1;
```

The embedded table becomes a nested field in the result type:

```gleam
pub type GetBookWithAuthorRow {
  GetBookWithAuthorRow(authors: Author, title: String)
}
```

## JOIN support

Columns from JOINed tables are resolved when inferring result types:

```sql
-- name: GetBookWithAuthor :one
SELECT books.title, authors.name
FROM books
JOIN authors ON books.author_id = authors.id;
```

Both `title` from `books` and `name` from `authors` are correctly typed in the generated row type.

## RETURNING clause

Queries with a `RETURNING` clause (PostgreSQL) generate result types from the returned columns:

```sql
-- name: CreateAuthor :one
INSERT INTO authors (name, bio) VALUES ($1, $2)
RETURNING id, name;
```

```gleam
pub type CreateAuthorRow {
  CreateAuthorRow(id: Int, name: String)
}
```

## CTE (WITH clause)

Common Table Expressions are supported. sqlode strips the CTE prefix and infers types from the main query:

```sql
-- name: GetRecentAuthors :many
WITH filtered AS (
  SELECT id FROM authors WHERE id > 0
)
SELECT authors.id, authors.name
FROM authors
JOIN filtered ON authors.id = filtered.id;
```

## Type mapping

| SQL type | Gleam type |
|---|---|
| INT, INTEGER, SMALLINT, BIGINT, SERIAL, BIGSERIAL | Int |
| FLOAT, DOUBLE, REAL, NUMERIC, DECIMAL, MONEY | Float |
| BOOLEAN, BOOL | Bool |
| TEXT, VARCHAR, CHAR | String |
| BYTEA, BLOB, BINARY | BitArray |
| TIMESTAMP, DATETIME | String |
| DATE | String |
| TIME, TIMETZ, INTERVAL | String |
| UUID | String |
| JSON, JSONB | String |
| `TYPE[]`, `TYPE ARRAY` | `List(TYPE)` |
| CITEXT, INET, CIDR, MACADDR, XML, BIT, TSVECTOR, TSQUERY | String |
| POINT, LINE, LSEG, BOX, PATH, POLYGON, CIRCLE | String |
| PostgreSQL ENUM | Generated custom type (with to_string/from_string helpers) |

Nullable columns (without `NOT NULL`) are wrapped in `Option(T)`.

## Overrides

Type overrides and column renames can be configured per SQL block:

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
          gleam_type: "String"
      renames:
        - table: "authors"
          column: "bio"
          rename_to: "biography"
```

Type overrides support two targeting modes:

- **`db_type`**: Overrides all columns of a given database type (e.g., all `uuid` columns become `String`)
- **`column`**: Overrides a specific column using `table.column` format (e.g., only `users.id` becomes `String`)

Column-level overrides take precedence over `db_type` overrides.

### Custom type aliases

When you specify a non-primitive `gleam_type` (e.g., `UserId` instead of `Int`), sqlode preserves the type name in generated record fields but uses the underlying primitive type for encoding and decoding.

The custom type must be a transparent type alias, not an opaque type:

```gleam
// OK — transparent type alias
pub type UserId = Int

// Error — opaque type
pub opaque type UserId {
  UserId(Int)
}
```

Opaque types are not supported because sqlode generates encoder/decoder calls that operate on the underlying primitive type (e.g., `runtime.int(params.id)`). If `UserId` is opaque, this will produce a compile error because `UserId` and `Int` are not interchangeable.

sqlode validates that `gleam_type` values start with an uppercase letter (valid Gleam type name) and emits a warning during generation when custom types are used.

### Semantic type mappings

By default, sqlode maps UUID, JSON, DATE, TIME, and TIMESTAMP columns to `String`. You can enable semantic type aliases with the `type_mapping` option:

```yaml
gen:
  gleam:
    out: "src/db"
    type_mapping: "rich"
```

sqlode emits type aliases for database types in `models.gleam`:

| SQL type | `string` (default) | `rich` | `strong` |
|----------|-------------------|--------|----------|
| TIMESTAMP / DATETIME | `String` | `SqlTimestamp` | `SqlTimestamp(String)` |
| DATE | `String` | `SqlDate` | `SqlDate(String)` |
| TIME / TIMETZ | `String` | `SqlTime` | `SqlTime(String)` |
| UUID | `String` | `SqlUuid` | `SqlUuid(String)` |
| JSON / JSONB | `String` | `SqlJson` | `SqlJson(String)` |

**`rich`**: Type aliases over `String`. Readable in signatures but not enforced by the compiler.

**`strong`**: Single-constructor wrapper types with unwrap helpers (e.g. `sql_uuid_to_string`). `SqlUuid` and `String` are distinct at compile time. Generated adapters wrap decoded values and unwrap encoded values automatically.

Example with `type_mapping: "strong"`:

```gleam
// Generated in models.gleam
pub type SqlUuid {
  SqlUuid(String)
}

pub fn sql_uuid_to_string(value: SqlUuid) -> String {
  let SqlUuid(inner) = value
  inner
}
```

## Config options

### emit_sql_as_comment

When set to `true`, each generated adapter function includes the original SQL as a comment:

```yaml
gen:
  gleam:
    out: "src/db"
    emit_sql_as_comment: true
```

### emit_exact_table_names

When set to `true`, table type names use the exact table name instead of singularized form:

```yaml
gen:
  gleam:
    out: "src/db"
    emit_exact_table_names: true
```

For example, a table named `authors` generates `pub type Authors { ... }` instead of the default `pub type Author { ... }`.

## CLI

```
# Standalone escript
sqlode generate [--config=./sqlode.yaml]
sqlode init [--output=./sqlode.yaml]

# Via Gleam
gleam run -m sqlode -- generate [--config=./sqlode.yaml]
gleam run -m sqlode -- init [--output=./sqlode.yaml]
```

## Migrating from sqlc

sqlode follows sqlc conventions, so most SQL files work without changes. Key differences:

| | sqlc | sqlode |
|---|---|---|
| Install | Standalone binary (`brew install sqlc`) | Escript or `gleam add sqlode` |
| Config | `sqlc.yaml` / `sqlc.json` | `sqlode.yaml` (v2 format only), also accepts `sqlc.yaml` / `sqlc.yml` / `sqlc.json` on autodiscovery |
| Generate | `sqlc generate` | `sqlode generate` |
| Init | `sqlc init` | `sqlode init` |
| Vet/Verify | `sqlc vet`, `sqlc verify` | Not supported |
| Target language | Go, Python, Kotlin, etc. | Gleam |
| Runtime | Generated code is self-contained | Generated code imports `sqlode/runtime` by default; set `vendor_runtime: true` to vendor a copy and drop the runtime dependency (see [Self-contained generation](#self-contained-generation-vendor_runtime)) |

### Migration steps

1. Install sqlode (see [Install](#install) above).
2. Keep your existing `sqlc.yaml` / `sqlc.yml` / `sqlc.json` in place — `sqlode generate` auto-discovers them in the current directory when `--config` is not passed. (The search order is `sqlode.yaml`, `sqlode.yml`, `sqlc.yaml`, `sqlc.yml`, `sqlc.json`; if more than one exists, pass `--config=<path>` to pick explicitly.) If you prefer a dedicated file, copy the config to `sqlode.yaml`. Either way keep `version: "2"` and the `sql` blocks. Replace the `gen` section:

   ```yaml
   gen:
     gleam:
       out: "src/db"
       runtime: "raw"   # or "native" for full adapter generation
   ```

3. Replace `sqlc.arg(...)`, `sqlc.narg(...)`, `sqlc.slice(...)`, and `sqlc.embed(...)` with `sqlode.arg(...)`, `sqlode.narg(...)`, `sqlode.slice(...)`, and `sqlode.embed(...)` in your `.sql` query files. The `@name` shorthand remains unchanged.

4. Run `sqlode generate` (or `gleam run -m sqlode -- generate`).

### Unsupported sqlc features

- `sqlc.yaml` v1 format
- `vet` and `verify` commands
- `emit_json_tags` and other sqlc-specific emit options not listed above
- MySQL adapter generation (`runtime: "raw"` works for MySQL)

## License

[MIT](./LICENSE)
