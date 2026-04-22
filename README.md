# sqlode

[![Hex](https://img.shields.io/hexpm/v/sqlode)](https://hex.pm/packages/sqlode)
[![Hex Downloads](https://img.shields.io/hexpm/dt/sqlode)](https://hex.pm/packages/sqlode)
[![CI](https://github.com/nao1215/sqlode/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/sqlode/actions/workflows/ci.yml)
[![license](https://img.shields.io/github/license/nao1215/sqlode)](./LICENSE)

sqlode reads SQL schema and query files and generates typed Gleam code. It follows the sqlc workflow: write SQL, run the generator, call the generated functions.

sqlode is inspired by [sqlc](https://sqlc.dev/) but is not a drop-in replacement. Macros use the `sqlode.*` prefix — `sqlc.*` is not accepted.

Supported engines (raw and native): PostgreSQL (`pog`), MySQL 8.0 (`shork`), SQLite (`sqlight`). The per-engine support matrix lives in [`doc/capabilities.md`](doc/capabilities.md).

First time here? [`doc/tutorials/getting-started-sqlite.md`](doc/tutorials/getting-started-sqlite.md) walks through a SQLite project end to end, and [`examples/sqlite-basic/`](examples/sqlite-basic/) is the runnable version of the same tutorial. The rest of this README is reference material.

## Getting started

### Install

sqlode ships as an Erlang escript, so most paths need Erlang/OTP on the host. Option D (Docker) bundles Erlang and is the one exception.

Whichever install path you pick, your Gleam project still needs `gleam add sqlode` because generated code imports `sqlode/runtime`.

#### A. One-line installer

```console
curl -fsSL https://raw.githubusercontent.com/nao1215/sqlode/main/scripts/install.sh | sh
```

Writes the latest release escript to `$HOME/.local/bin/sqlode` and warns if Erlang/OTP is missing. To review the script first, download it, read it, then `sh install.sh`.

Environment variables:

- `SQLODE_VERSION=v0.1.0` pins a release tag instead of `latest`.
- `SQLODE_INSTALL_DIR=/path/to/bin` installs elsewhere. System paths need `sudo`.

If `$HOME/.local/bin` is not on your `PATH`, add it:

```console
export PATH="$HOME/.local/bin:$PATH"
```

#### B. Manual escript download

Grab the escript from [GitHub Releases](https://github.com/nao1215/sqlode/releases) and put it on your `PATH`:

```console
chmod +x sqlode
./sqlode generate --config=sqlode.yaml
```

#### C. Run via Gleam

```console
gleam add sqlode
gleam run -m sqlode -- generate
```

#### D. Docker (no Erlang install)

```console
docker run --rm -v "$PWD:/work" ghcr.io/nao1215/sqlode:latest init --engine=sqlite
docker run --rm -v "$PWD:/work" ghcr.io/nao1215/sqlode:latest generate
```

The container's working directory is `/work`, so mounting your project there lets `init` / `generate` / `verify` write into the host. Swap `:latest` for a version tag (`:0.7.0`) to pin a release. The `:latest` tag appears once the docker workflow has run on `main`; before that, `docker build -t sqlode .` at the repo root produces the same image.

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

`schema` and `queries` each take a single path, a list of paths, or a directory (sqlode then picks up every `.sql` in it). An optional `name` on each `sql` block shows up in diagnostics when several blocks are configured.

The schema parser accepts either a schema snapshot or a migration history (additive and destructive DDL both work). The full supported-statement list is in [Schema DDL scope](#schema-ddl-scope).

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

This writes `params.gleam` and `queries.gleam` under the configured output directory. `models.gleam` is added when the schema defines tables or when a `:one` / `:many` query returns result columns.

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

One record per table in the schema, plus row types for queries that return results. When a query's columns exactly match a table (same columns, types, nullability, order), sqlode emits an alias instead of a duplicate record.

```gleam
// Table record (singularized), reusable across queries
pub type Author {
  Author(id: Int, name: String, bio: Option(String), created_at: String)
}

// Exact match: alias
pub type GetAuthorRow =
  Author

// Partial match: separate row type
pub type ListAuthorsRow {
  ListAuthorsRow(id: Int, name: String)
}
```

### queries.gleam

Each query is a `RawQuery(params)`. `all()` / `QueryInfo` enumerate queries without type parameters.

```gleam
pub type QueryInfo {
  QueryInfo(name: String, sql: String, command: runtime.QueryCommand, param_count: Int)
}

pub fn all() -> List(QueryInfo) { ... }

pub fn get_author() -> runtime.RawQuery(params.GetAuthorParams) { ... }
pub fn list_authors() -> runtime.RawQuery(Nil) { ... }
pub fn create_author() -> runtime.RawQuery(params.CreateAuthorParams) { ... }
```

For the common case, call the generated `prepare_*` helper. It builds the params record and returns the `(sql, values)` tuple that Gleam database drivers accept directly:

```gleam
let #(sql, values) = queries.prepare_get_author(id: 1)
// sql: "... WHERE id = $1"
```

`sqlode.slice` works the same way — pass a `List`, the SQL expands to the right number of placeholders:

```gleam
let #(sql, values) = queries.prepare_get_authors_by_ids(ids: [1, 2, 3])
// sql: "... WHERE id IN ($1, $2, $3)"
```

If you need the `RawQuery` descriptor (caching, batching, custom wrappers), the low-level shape is still there:

```gleam
let q = queries.get_author()
let #(sql, values) = runtime.prepare(q, params.GetAuthorParams(id: 1))
```

The placeholder dialect (`$1` / `?`) is baked into the `RawQuery`, so `runtime.prepare` does not take it as an argument.

## Runtime modes

The `runtime` option controls what code sqlode emits.

| Mode | Generated files | DB driver | Use case |
|------|----------------|-----------|----------|
| `raw` | queries, params, models | — | You run the queries yourself |
| `native` | queries, params, models, adapter | pog / sqlight / shork | Full adapter: bind params, decode rows |

sqlode itself must be a runtime dependency (not just dev) because the generated code imports `sqlode/runtime`. `native` mode also needs a driver:

```console
gleam add sqlode
gleam add pog       # PostgreSQL native
gleam add sqlight   # SQLite native
gleam add shork     # MySQL native
```

### Self-contained generation (`vendor_runtime`)

`gen.gleam.vendor_runtime: true` copies the `sqlode/runtime` module into the output directory as `runtime.gleam` and rewrites the generated imports to match. The generated package then only needs sqlode as a dev dependency. Native adapters still need their driver.

```yaml
gen:
  gleam:
    out: "src/db"
    runtime: "raw"
    vendor_runtime: true
```

Shared-runtime is smaller and updates with `gleam update sqlode`; vendored is self-contained but has to be regenerated to pick up runtime changes.

## Adapter generation

With `runtime: "native"`, sqlode generates an adapter that wraps [pog](https://hexdocs.pm/pog/) (PostgreSQL), [sqlight](https://hexdocs.pm/sqlight/) (SQLite), or [shork](https://hexdocs.pm/shork/) (MySQL 8.0). The three adapters have the same shape; MySQL routes `:execrows` through `SELECT ROW_COUNT()` and `:execlastid` through `SELECT LAST_INSERT_ID()` under the hood.

Out of scope today: MariaDB is not separately validated — the `mysql` engine targets MySQL 8.0. `:execresult` is rejected on every native target; use `:exec`, `:execrows`, or `:execlastid`. `BLOB` / `BINARY` round-trip through `shork_ffi.coerce` (the same identity FFI shork's value constructors use), so no shork API extension is needed.

```yaml
gen:
  gleam:
    out: "src/db"
    runtime: "native"
```

An adapter function handles parameter binding, execution, and decoding:

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

#### MySQL examples

MySQL works in both modes. `raw` returns the prepared SQL plus encoded params; `native` generates a `mysql_adapter` that wraps `shork`.

##### MySQL raw mode

```yaml
sql:
  - engine: "mysql"
    schema: "db/schema.sql"
    queries: "db/query.sql"
    gen:
      gleam:
        out: "src/db"
        runtime: "raw"
```

```sql
-- name: GetAuthor :one
SELECT id, email, display_name
FROM authors
WHERE id = ?;
```

```gleam
import db/params
import db/queries
import sqlode/runtime

pub fn fetch(id: Int) -> #(String, List(runtime.Value)) {
  runtime.prepare(queries.get_author(), params.GetAuthorParams(id:))
}
```

##### MySQL native mode

```yaml
sql:
  - engine: "mysql"
    schema: "db/schema.sql"
    queries: "db/query.sql"
    gen:
      gleam:
        out: "src/db"
        runtime: "native"
```

```gleam
import db/mysql_adapter
import db/params
import gleam/option
import shork

pub fn main() {
  let assert Ok(db) = shork.connect(shork.default_config())

  // :execlastid — returns the AUTO_INCREMENT id of the new row.
  let assert Ok(id) =
    mysql_adapter.create_author(
      db,
      params.CreateAuthorParams(
        email: "alice@example.com",
        display_name: "Alice",
        bio: option.None,
        is_active: True,
        avatar: option.None,
      ),
    )

  // :one — returns Result(Option(Row), shork.QueryError).
  let assert Ok(option.Some(author)) =
    mysql_adapter.get_author(db, params.GetAuthorParams(id:))
  let _ = author.display_name
  Nil
}
```

#### Return types by annotation

| Annotation | sqlight return type | pog return type | shork return type |
|---|---|---|---|
| `:one` | `Result(Option(Row), sqlight.Error)` | `Result(Option(Row), pog.QueryError)` | `Result(Option(Row), shork.QueryError)` |
| `:many` | `Result(List(Row), sqlight.Error)` | `Result(List(Row), pog.QueryError)` | `Result(List(Row), shork.QueryError)` |
| `:exec` | `Result(Nil, sqlight.Error)` | `Result(Nil, pog.QueryError)` | `Result(Nil, shork.QueryError)` |
| `:execrows` | `Result(Int, sqlight.Error)` | `Result(Int, pog.QueryError)` | `Result(Int, shork.QueryError)` |
| `:execlastid` | `Result(Int, sqlight.Error)` | `Result(Int, pog.QueryError)` | `Result(Int, shork.QueryError)` |

`:batchone`, `:batchmany`, `:batchexec`, and `:copyfrom` are not implemented and fail generation — see [Planned annotations](#planned-annotations).

`:execresult` is `raw` only. Native rejects it because it is indistinguishable from `:execrows` once rows are decoded.

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

Reserved for future work; any use fails generation today.

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

Prefix with `-- sqlode:skip` to exclude a query from generation — useful when the SQL uses syntax sqlode cannot yet parse.

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

The embedded table becomes a nested field:

```gleam
pub type GetBookWithAuthorRow {
  GetBookWithAuthorRow(authors: Author, title: String)
}
```

## JOIN support

Columns from JOINed tables are resolved against their source tables:

```sql
-- name: GetBookWithAuthor :one
SELECT books.title, authors.name
FROM books
JOIN authors ON books.author_id = authors.id;
```

`books.title` and `authors.name` end up correctly typed in the generated row.

## RETURNING clause

PostgreSQL `RETURNING` columns become the result type:

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

Common Table Expressions are supported — sqlode strips the CTE prefix and infers types from the main query:

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

Nullable columns (no `NOT NULL`) are wrapped in `Option(T)`.

## Overrides

Each `sql` block can carry type overrides and column renames:

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

Two targeting modes:

- `db_type` — every column of a given database type (e.g. every `uuid` becomes `String`).
- `column` — a specific column via `table.column` (e.g. only `users.id`).

Column-level overrides win over `db_type` overrides.

### Custom type aliases

A non-primitive `gleam_type` (e.g. `UserId` instead of `Int`) keeps the name in generated record fields but encodes and decodes through the underlying primitive.

Opaque types are not supported — the mapped type must be a transparent alias. Opaque single-constructor types fail to compile because the generated code calls primitive encoders (like `runtime.int(params.id)`) directly on the value. A codec hook for opaque types is tracked for a future release.

```gleam
// OK: transparent alias
pub type UserId = Int

// Error: opaque
pub opaque type UserId {
  UserId(Int)
}
```

sqlode checks that `gleam_type` starts with an uppercase letter and warns when custom types are in play.

### Semantic type mappings

By default UUID, JSON, DATE, TIME, TIMESTAMP become `String`. `type_mapping` opts into richer aliases:

```yaml
gen:
  gleam:
    out: "src/db"
    type_mapping: "rich"
```

| SQL type | `string` (default) | `rich` | `strong` |
|----------|-------------------|--------|----------|
| TIMESTAMP / DATETIME | `String` | `SqlTimestamp` | `SqlTimestamp(String)` |
| DATE | `String` | `SqlDate` | `SqlDate(String)` |
| TIME / TIMETZ | `String` | `SqlTime` | `SqlTime(String)` |
| UUID | `String` | `SqlUuid` | `SqlUuid(String)` |
| JSON / JSONB | `String` | `SqlJson` | `SqlJson(String)` |

`rich` is a plain `String` alias — readable in signatures, not enforced by the compiler. `strong` emits a single-constructor wrapper with an `*_to_string` helper; `SqlUuid` and `String` are then distinct at compile time, and adapters wrap / unwrap values automatically.

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

## Limitations

sqlode is still early. A few constraints to check before adopting it; most are tracked for future releases.

### Parameter type inference

sqlode infers a parameter's type from its surrounding SQL. Four contexts are recognised today:

1. `INSERT INTO t (col) VALUES ($1)` — parameter inherits `col`'s type.
2. `WHERE col = $1` (and `!=`, `<`, `<=`, `>`, `>=`).
3. `WHERE col IN ($1, $2, ...)` and `sqlode.slice($1)`.
4. `$1::int` / `CAST($1 AS int)` — explicit cast.

Anywhere else, sqlode fails generation with:

> `Query "Name": could not infer type for parameter $N. Use a type cast (e.g. $N::int) to specify the type`

Cases that need an explicit cast today: scalar arithmetic (`price + $1`), parameters inside `CASE WHEN` branches whose other branches are also parameters, and function arguments sqlode does not yet recognise. Pin the type with `$N::int` (PostgreSQL) or `CAST($N AS INTEGER)` (SQLite).

### Schema DDL scope

The schema parser accepts both schema snapshots and migration histories (including destructive DDL). Supported statements:

- `CREATE TABLE`, `CREATE VIEW`, `CREATE TYPE` (enum)
- `ALTER TABLE ... ADD COLUMN` / `DROP COLUMN`
- `ALTER TABLE ... RENAME TO` / `RENAME COLUMN`
- `ALTER TABLE ... ALTER COLUMN TYPE` / `SET NOT NULL` / `DROP NOT NULL`
- `DROP TABLE`, `DROP VIEW`, `DROP TYPE`

Anything else (`CREATE INDEX`, transaction blocks, comments) is silently skipped.

### View resolution

`CREATE VIEW ... AS SELECT ...` columns resolve against the base tables so generated models have real types. By default sqlode fails generation when any view column cannot be resolved — a partially resolved view is almost always a sign that the schema and the config have drifted, and silently dropping columns lets that drift reach generated code.

If you need the old warn-and-continue behaviour, set `strict_views: false`:

```yaml
sql:
  - schema: "db/schema.sql"
    queries: "db/query.sql"
    engine: "postgresql"
    gen:
      gleam:
        out: "src/db"
        strict_views: false
```

Unresolvable columns are then printed to stderr and dropped (or the whole view is dropped if nothing resolves).

### Custom types must be transparent aliases

See [Custom type aliases](#custom-type-aliases). Opaque types (`pub opaque type Foo { ... }`) are not supported.

## Config options

### emit_sql_as_comment

Attach the original SQL as a comment on each generated adapter function.

```yaml
gen:
  gleam:
    out: "src/db"
    emit_sql_as_comment: true
```

### emit_exact_table_names

Keep table names as-is instead of singularising. `authors` stays `pub type Authors { ... }` (default would be `Author`).

```yaml
gen:
  gleam:
    out: "src/db"
    emit_exact_table_names: true
```

## CLI

```
# Standalone escript
sqlode generate [--config=./sqlode.yaml]
sqlode verify   [--config=./sqlode.yaml]
sqlode init     [--output=./sqlode.yaml]

# Via Gleam
gleam run -m sqlode -- generate [--config=./sqlode.yaml]
gleam run -m sqlode -- verify   [--config=./sqlode.yaml]
gleam run -m sqlode -- init     [--output=./sqlode.yaml]
```

### `sqlode verify`

`verify` is the static check lane for CI. It loads the project like `generate` does — schema parsing, query parsing, analyser pass — but writes no files and collects every failure into a single report instead of short-circuiting on the first error.

```
$ sqlode verify
Verifying config: sqlode.yaml
[src/db] query "FilterAuthors" has 4 inferred parameter(s), exceeds query_parameter_limit 3
```

Non-zero exit on any finding, so it gates generation in CI:

```yaml
- run: sqlode verify
- run: sqlode generate
```

Per-block policies `verify` honours:

- `strict_views` — promote view-resolution warnings to findings (same as `generate`).
- `query_parameter_limit` — per-query cap on inferred parameters, mirroring sqlc's option. Unset means no limit.

### Verification roadmap

Today's command covers the static phase of Issue #395. Future phases are additive — new findings show up in the existing `Report` without breaking the CLI contract:

1. Static analysis (shipped) — schema + query parsing, analyser pass, `query_parameter_limit`.
2. DB-backed analysis — a `database` / `analyzer` config that runs queries through `EXPLAIN` against a real database to catch view drift and engine-specific typing the local analyser misses.
3. Execution-lane validation — running generated code against an ephemeral test DB as part of `verify`.

## Migrating from sqlc

sqlode follows sqlc conventions, so most SQL files move over untouched. The differences:

| | sqlc | sqlode |
|---|---|---|
| Install | Standalone binary (`brew install sqlc`) | Escript or `gleam add sqlode` |
| Config | `sqlc.yaml` / `sqlc.json` | `sqlode.yaml` (v2 format only), also accepts `sqlc.yaml` / `sqlc.yml` / `sqlc.json` on autodiscovery |
| Generate | `sqlc generate` | `sqlode generate` |
| Init | `sqlc init` | `sqlode init` |
| Vet/Verify | `sqlc vet`, `sqlc verify` | `sqlode verify` (static analysis + `query_parameter_limit`); DB-backed analyser is on the [verification roadmap](#verification-roadmap) |
| Target language | Go, Python, Kotlin, etc. | Gleam |
| Runtime | Generated code is self-contained | Generated code imports `sqlode/runtime` by default; set `vendor_runtime: true` to vendor a copy and drop the runtime dependency (see [Self-contained generation](#self-contained-generation-vendor_runtime)) |

### Migration steps

1. Install sqlode — see [Install](#install).
2. Keep your existing `sqlc.yaml` / `sqlc.yml` / `sqlc.json`. `sqlode generate` auto-discovers them in the current directory when no `--config` is passed (search order: `sqlode.yaml`, `sqlode.yml`, `sqlc.yaml`, `sqlc.yml`, `sqlc.json`; pass `--config=<path>` if more than one exists). If you prefer a dedicated file, copy the config to `sqlode.yaml`. Either way, keep `version: "2"` and the `sql` blocks and replace the `gen` section:

   ```yaml
   gen:
     gleam:
       out: "src/db"
       runtime: "raw"   # or "native"
   ```

3. Swap `sqlc.arg` / `sqlc.narg` / `sqlc.slice` / `sqlc.embed` for the `sqlode.*` versions in your `.sql` files. The `@name` shorthand is unchanged.
4. Run `sqlode generate` (or `gleam run -m sqlode -- generate`).

### Unsupported sqlc features

- `sqlc.yaml` v1 format
- `vet` and `verify` commands
- `emit_json_tags` and other sqlc-specific emit options not listed above

## License

[MIT](./LICENSE)
