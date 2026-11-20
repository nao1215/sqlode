# sqlode

[![CI](https://github.com/nao1215/sqlode/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/sqlode/actions/workflows/ci.yml)
[![Gitleaks](https://github.com/nao1215/sqlode/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/nao1215/sqlode/actions/workflows/gitleaks.yml)
[![Trivy](https://github.com/nao1215/sqlode/actions/workflows/trivy.yml/badge.svg)](https://github.com/nao1215/sqlode/actions/workflows/trivy.yml)
[![OSV-Scanner](https://github.com/nao1215/sqlode/actions/workflows/osv-scan.yml/badge.svg)](https://github.com/nao1215/sqlode/actions/workflows/osv-scan.yml)
[![tested with atago](https://img.shields.io/badge/tested%20with-atago-7c3aed?logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI%2BPHBhdGggZmlsbD0iI2ZmZiIgZD0iTTMuNiA0LjIgMTEuOSAxMmwtOC4zIDcuOC0xLjktMi4yTDcuOSAxMiAxLjcgNi40eiIvPjxyZWN0IGZpbGw9IiNmZmYiIHg9IjEyLjYiIHk9IjE3LjIiIHdpZHRoPSI5LjciIGhlaWdodD0iMi44IiByeD0iMS40Ii8%2BPC9zdmc%2B&logoColor=white)](https://github.com/nao1215/atago)
[![measured with himorime](https://img.shields.io/badge/measured%20with-himorime-d9480f?logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI%2BPHBhdGggZmlsbD0ibm9uZSIgc3Ryb2tlPSIjZmZmIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBkPSJNNC4yIDE4LjVBOSA5IDAgMSAxIDE5LjggMTguNSIvPjxwYXRoIGZpbGw9Im5vbmUiIHN0cm9rZT0iI2ZmZiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgZD0iTTEyIDE0LjUgMTYuNSA5Ii8%2BPGNpcmNsZSBmaWxsPSIjZmZmIiBjeD0iMTIiIGN5PSIxNC41IiByPSIyLjIiLz48L3N2Zz4=&logoColor=white)](https://github.com/nao1215/himorime)
[![Hex](https://img.shields.io/hexpm/v/sqlode)](https://hex.pm/packages/sqlode)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/sqlode/)
[![Hex Downloads](https://img.shields.io/hexpm/dt/sqlode)](https://hex.pm/packages/sqlode)
[![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/nao1215/sqlode/total)](https://github.com/nao1215/sqlode/releases)
[![License](https://img.shields.io/github/license/nao1215/sqlode)](./LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nao1215/sqlode/badge)](https://scorecard.dev/viewer/?uri=github.com/nao1215/sqlode)

sqlode reads SQL schema and query files and generates typed Gleam code, following the [sqlc](https://sqlc.dev/) workflow: write SQL, run the generator, call the generated functions. It is not a drop-in replacement for sqlc; macros use the `sqlode.*` prefix and `sqlc.*` is not accepted.

It supports PostgreSQL (`pog`), MySQL 8.0 (`shork`) and SQLite (`sqlight`), each in raw and native mode; [`doc/capabilities.md`](doc/capabilities.md) has the matrix. [`doc/tutorials/getting-started-sqlite.md`](doc/tutorials/getting-started-sqlite.md) walks through a SQLite project, and [`examples/sqlite-basic/`](examples/sqlite-basic/) is the runnable version.

## Quickstart (SQLite)

This needs only `gleam`, with sqlode as a dependency.

```console
gleam new myapp
cd myapp
gleam add sqlode sqlight
gleam run -m sqlode -- init --engine=sqlite --runtime=native
gleam run -m sqlode -- generate
```

`init` writes `sqlode.yaml` and stub `db/schema.sql` / `db/query.sql` files, so `generate` works on the first run. `--runtime=native` (default `raw`) makes `generate` write a `sqlight` adapter; without it you get `runtime.Value` lists for your own adapter. `sqlode.yaml` records the choice:

```yaml
version: "2"
sql:
  - schema: "db/schema.sql"
    queries: "db/query.sql"
    engine: "sqlite"
    gen:
      gleam:
        out: "src/db"
        runtime: "native"
```

Then replace the stubs with your own schema and queries and run `gleam run -m sqlode -- generate` again:

```sql
-- db/schema.sql
CREATE TABLE authors (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  bio TEXT
);

-- db/query.sql
-- name: GetAuthor :one
SELECT id, name, bio FROM authors WHERE id = ?;

-- name: CreateAuthor :exec
INSERT INTO authors (name, bio)
VALUES (sqlode.arg(author_name), sqlode.narg(bio));
```

```console
$ gleam run -m sqlode -- generate
Loading config from: sqlode.yaml

Successfully generated 4 files
  Generated: src/db/params.gleam
  Generated: src/db/queries.gleam
  Generated: src/db/models.gleam
  Generated: src/db/sqlight_adapter.gleam
  Formatted generated code
```

`src/db/sqlight_adapter.gleam` now has typed functions such as:

```gleam
pub fn get_author(
  db: sqlight.Connection,
  p: params.GetAuthorParams,
) -> Result(Option(models.GetAuthorRow), sqlight.Error)
```

[Using the generated adapter](#using-the-generated-adapter) has a full `main.gleam`.

## Targets

- The CLI is an escript and runs on BEAM only, as do the `pog`, `shork` and `sqlight` drivers.
- `sqlode/runtime` has no FFI and works on both targets. `prepare(query, params)` returns `#(String, List(Value))`.
- Generated modules depend only on `sqlode/runtime` and your driver, so they run on JavaScript when a JavaScript driver exists.

## Getting started

### Install

The CLI is an Erlang escript, so it needs Erlang/OTP, except in Docker (D); mise (E) manages both. Your Gleam project also needs `gleam add sqlode`, because generated code imports `sqlode/runtime`.

#### A. One-line installer

```console
curl -fsSL https://raw.githubusercontent.com/nao1215/sqlode/main/scripts/install.sh | sh
```

It writes the latest escript to `$HOME/.local/bin/sqlode` and warns if Erlang/OTP is missing. To review the script first, download it, read it, then run `sh install.sh`.

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

The working directory is `/work`, so `init`, `generate` and `verify` write into the mounted project. Use a version tag (`:0.35.0`) to pin a release, or `docker build -t sqlode .` at the repo root to build the image.

#### E. mise (recommended for Gleam projects)

With [mise](https://mise.jdx.dev/):

```console
mise plugin add sqlode https://github.com/nao1215/sqlode.git#mise-plugin
mise install sqlode@latest
```

Pin a version in `.mise.toml`:

```toml
[tools]
sqlode = "0.35.0"
```

#### Verifying release integrity

From v0.34.0, each release carries `SHA256SUMS` (the escript, its CycloneDX SBOM `sqlode.cdx.json` and the bundled third-party licenses), a cosign keyless signature of it, and SLSA provenance. With the release files in the current directory:

```console
sha256sum -c SHA256SUMS
cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp '^https://github.com/nao1215/sqlode/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
gh attestation verify sqlode --repo nao1215/sqlode
slsa-verifier verify-artifact --provenance-path multiple.intoto.jsonl \
  --source-uri github.com/nao1215/sqlode --source-tag v0.35.0 sqlode
```

The Docker image is signed by digest: `cosign verify ghcr.io/nao1215/sqlode:0.35.0 --certificate-identity-regexp '^https://github.com/nao1215/sqlode/' --certificate-oidc-issuer https://token.actions.githubusercontent.com`.

### A PostgreSQL project

`sqlode init` (or `gleam run -m sqlode -- init`) without flags writes this `sqlode.yaml` and stub `db/schema.sql` and `db/query.sql` files:

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

`schema` and `queries` each take a path, a list of paths, or a directory of `.sql` files. An optional `name` on a `sql` block labels its diagnostics. The schema can be a snapshot or a migration history; see [Schema DDL scope](#schema-ddl-scope).

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

`sqlode generate` writes `params.gleam` and `queries.gleam` to the output directory, plus `models.gleam` when the schema has tables or a `:one` / `:many` query returns columns.

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

One record per table, plus row types for queries that return results. When a query's columns match a table exactly (columns, types, nullability, order), the row type is an alias.

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

Each query is a `RawQuery(params)`. `all()` lists them as `QueryInfo` values.

```gleam
pub type QueryInfo {
  QueryInfo(name: String, sql: String, command: runtime.QueryCommand, param_count: Int)
}

pub fn all() -> List(QueryInfo) { ... }

pub fn get_author() -> runtime.RawQuery(params.GetAuthorParams) { ... }
pub fn list_authors() -> runtime.RawQuery(Nil) { ... }
pub fn create_author() -> runtime.RawQuery(params.CreateAuthorParams) { ... }
```

The generated `prepare_*` helpers build the params record and return the `(sql, values)` tuple that Gleam database drivers take:

```gleam
let #(sql, values) = queries.prepare_get_author(id: 1)
// sql: "... WHERE id = $1"
```

With `sqlode.slice`, pass a `List` and the SQL expands to one placeholder per element:

```gleam
let #(sql, values) = queries.prepare_get_authors_by_ids(ids: [1, 2, 3])
// sql: "... WHERE id IN ($1, $2, $3)"
```

For caching, batching or custom wrappers, use the `RawQuery` directly:

```gleam
let q = queries.get_author()
let #(sql, values) = runtime.prepare(q, params.GetAuthorParams(id: 1))
```

The `RawQuery` carries the placeholder dialect (`$1` / `?`), so `runtime.prepare` does not take it.

## Runtime modes

The `runtime` option controls what code sqlode emits.

| Mode | Generated files | DB driver | Use case |
|------|----------------|-----------|----------|
| `raw` | queries, params, models | — | You run the queries yourself |
| `native` | queries, params, models, adapter | pog / sqlight / shork | Full adapter: bind params, decode rows |

sqlode must be a runtime dependency, not a dev dependency, because the generated code imports `sqlode/runtime`. `native` mode also needs a driver:

```console
gleam add sqlode
gleam add pog       # PostgreSQL native
gleam add sqlight   # SQLite native
gleam add shork     # MySQL native
```

### Self-contained generation (`vendor_runtime`)

`gen.gleam.vendor_runtime: true` copies `sqlode/runtime` into the output directory as `runtime.gleam` and points the generated imports at it, so sqlode becomes a dev dependency. Native adapters still need their driver.

```yaml
gen:
  gleam:
    out: "src/db"
    runtime: "raw"
    vendor_runtime: true
```

The shared runtime updates with `gleam update sqlode`; a vendored copy changes only when you regenerate.

## Adapter generation

With `runtime: "native"`, sqlode generates an adapter that wraps [pog](https://hexdocs.pm/pog/) (PostgreSQL), [sqlight](https://hexdocs.pm/sqlight/) (SQLite) or [shork](https://hexdocs.pm/shork/) (MySQL 8.0). The three have the same shape. On MySQL, `:execrows` runs `SELECT ROW_COUNT()` and `:execlastid` runs `SELECT LAST_INSERT_ID()`, and `BLOB` / `BINARY` go through `shork_ffi.coerce`, the identity FFI that shork's value constructors use. MariaDB is not tested separately.

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

[doc/adapter-examples.md](doc/adapter-examples.md) has the PostgreSQL and MySQL versions.

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

#### Return types by annotation

| Annotation | sqlight return type | pog return type | shork return type |
|---|---|---|---|
| `:one` | `Result(Option(Row), sqlight.Error)` | `Result(Option(Row), pog.QueryError)` | `Result(Option(Row), shork.QueryError)` |
| `:many` | `Result(List(Row), sqlight.Error)` | `Result(List(Row), pog.QueryError)` | `Result(List(Row), shork.QueryError)` |
| `:exec` | `Result(Nil, sqlight.Error)` | `Result(Nil, pog.QueryError)` | `Result(Nil, shork.QueryError)` |
| `:execrows` | `Result(Int, sqlight.Error)` | `Result(Int, pog.QueryError)` | `Result(Int, shork.QueryError)` |
| `:execlastid` | `Result(Int, sqlight.Error)` | `Result(Int, pog.QueryError)` | `Result(Int, shork.QueryError)` |

`:execresult` is `raw` only: once rows are decoded it is the same as `:execrows`, so native rejects it. `:batchone`, `:batchmany`, `:batchexec` and `:copyfrom` fail generation; see [Planned annotations](#planned-annotations).

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

`-- sqlode:skip` excludes a query from generation, for SQL that sqlode cannot parse yet.

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

On all three engines each element is bound as its own value and the marker expands to that many placeholders (`$1, $2` on PostgreSQL, `?1, ?2` on SQLite, `?, ?` on MySQL). An empty list expands to `NULL`, so `IN (NULL)` matches no rows.

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

`books.title` and `authors.name` get their source columns' types.

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

sqlode strips the CTE prefix and infers types from the main query:

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

`db_type` applies to every column of that database type; `column` applies to one `table.column`. A `column` override wins over a `db_type` override.

### Custom type aliases

A non-primitive `gleam_type` such as `UserId` appears in the generated record fields, but by default the value is encoded and decoded as the underlying primitive. That works for a transparent alias:

```gleam
// OK: transparent alias — the underlying primitive encoders apply
// directly because `UserId` is just `Int` at runtime.
pub type UserId = Int
```

For an opaque wrapper type, add `encode` / `decode` hooks to the override, and the generated code converts through them:

```yaml
overrides:
  types:
    - db_type: "int"
      gleam_type: "myapp/types.UserId"
      encode: "user_id_to_int"
      decode: "int_to_user_id"
```

```gleam
// myapp/types.gleam
pub opaque type UserId {
  UserId(Int)
}

pub fn user_id_to_int(id: UserId) -> Int {
  let UserId(inner) = id
  inner
}

pub fn int_to_user_id(value: Int) -> UserId {
  UserId(value)
}
```

Config loading rejects an override with only one of `encode` and `decode`. The hooks are looked up in the module of `gleam_type`: for `myapp/types.UserId` the generated code calls `types.user_id_to_int(value)`. Without hooks, generation warns that the type must be a transparent alias. `gleam_type` must start with an uppercase letter, and `encode` / `decode` with a lowercase letter or underscore.

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

`rich` types are `String` aliases, so they document signatures without compiler checks. `strong` emits a wrapper with an `*_to_string` helper, which makes `SqlUuid` and `String` distinct types; adapters wrap and unwrap the values. With `type_mapping: "strong"`:

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

### Parameter type inference

sqlode infers a parameter's type from these contexts:

1. `INSERT INTO t (col) VALUES ($1)`: `col`'s type.
2. `WHERE col = $1` (and `!=`, `<`, `<=`, `>`, `>=`).
3. `WHERE col IN ($1, $2, ...)` and `sqlode.slice($1)`.
4. `WHERE col = ANY($1)`: a list of `col`'s type. `WHERE $1 = ANY(tags)`: an element of the array column.
5. `visits + $1`, `SET visits = visits + $1` (and `-`, `*`, `/`, `%`): the numeric column's type.
6. `LIMIT $1` / `OFFSET $1`: `Int`.
7. `$1::int` / `CAST($1 AS int)`: the cast type.

Anywhere else, sqlode fails generation with:

> `SQD4003: Query "Name": could not infer type for parameter $N. Use a type cast (e.g. $N::int) to specify the type`

This happens for arithmetic with a non-numeric operand (`created_at + $1`), `CASE WHEN` branches whose other branches are also parameters, and arguments of unrecognised functions. Add `$N::int` (PostgreSQL) or `CAST($N AS INTEGER)` (SQLite).

### Schema DDL scope

Schema snapshots and migration histories, including destructive DDL, both work. Supported statements:

- `CREATE TABLE`, `CREATE VIEW`, `CREATE TYPE` (enum)
- `ALTER TABLE ... ADD COLUMN` / `DROP COLUMN`
- `ALTER TABLE ... RENAME TO` / `RENAME COLUMN`
- `ALTER TABLE ... ALTER COLUMN TYPE` / `SET NOT NULL` / `DROP NOT NULL`
- `DROP TABLE`, `DROP VIEW`, `DROP TYPE`

Anything else (`CREATE INDEX`, transaction blocks, comments) is silently skipped.

### View resolution

View columns resolve against the base tables. If any view column cannot be resolved, generation fails, since that usually means the schema and the queries have drifted apart. `strict_views: false` warns instead:

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

Unresolvable columns are then printed to stderr and dropped, or the whole view if nothing resolves.

Without codec hooks, a custom `gleam_type` must be a transparent alias; see [Custom type aliases](#custom-type-aliases).

## Config options

### emit_sql_as_comment

Adds the original SQL as a comment on each generated adapter function.

```yaml
gen:
  gleam:
    out: "src/db"
    emit_sql_as_comment: true
```

### emit_exact_table_names

Keeps table names as they are: `authors` becomes `pub type Authors { ... }` instead of `Author`.

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
sqlode init     [--output=./sqlode.yaml] [--engine=postgresql|sqlite|mysql] [--runtime=raw|native]

# Via Gleam
gleam run -m sqlode -- generate [--config=./sqlode.yaml]
gleam run -m sqlode -- verify   [--config=./sqlode.yaml]
gleam run -m sqlode -- init     [--output=./sqlode.yaml] [--engine=postgresql|sqlite|mysql] [--runtime=raw|native]
```

Every error starts with a stable code, such as `Error: SQD4003: ...`, and exits 1. [doc/errors.md](doc/errors.md) explains each code and how to fix it.

### `sqlode verify`

`verify` parses and analyses the project like `generate` but writes no files, and reports every failure instead of stopping at the first. A clean project prints:

```console
$ sqlode verify
Verifying config: sqlode.yaml
All checks passed.
```

A finding prints its code and exits non-zero:

```
$ sqlode verify
Verifying config: sqlode.yaml
[src/db] SQD4012: query "FilterAuthors" has 4 inferred parameter(s), exceeds query_parameter_limit 3
```

In CI, run it before `generate`:

```yaml
- run: sqlode verify
- run: sqlode generate
```

It honours two per-block options: `strict_views`, as in `generate`, and `query_parameter_limit`, a per-query cap on inferred parameters like sqlc's (unset means no limit).

## More documentation

- [doc/migrating-from-sqlc.md](doc/migrating-from-sqlc.md): differences from sqlc and migration steps
- [doc/custom-adapters.md](doc/custom-adapters.md): using `sqlode/runtime` with another driver
- [doc/adapter-examples.md](doc/adapter-examples.md): PostgreSQL and MySQL adapter examples
- [doc/errors.md](doc/errors.md): every error code and its fix


## Testing

| Technique | Bug class caught here |
|---|---|
| Examples and unit tests | [Wrong parsing, inference and rendering per stage](doc/testing.md#examples-and-unit-tests) |
| Generated properties | [Encoders and naming helpers that break on unusual input](doc/testing.md#generated-properties) |
| Metamorphic relations | [Inference that depends on whitespace, comments, keyword case or query order](doc/testing.md#metamorphic-relations) |
| Snapshots | [Unreviewed changes to the generated code](doc/testing.md#snapshots) |
| Differential testing | [Parameter counts and result columns that differ from what SQLite reports for the same SQL](doc/testing.md#differential-testing-against-sqlite) |
| End-to-end tests and output snapshots | [Wrong exit codes, help text and reports of the shipped escript](doc/testing.md#end-to-end-tests) |
| Real databases | [Generated code that does not compile or does not match what the database returns](doc/testing.md#real-databases) |
| Mutation testing (local) | [Branches of the lexer and the analysers that no test pins down](doc/testing.md#mutation-testing) |
| Paired CI benchmarks | [Slower startup, generate and verify](doc/testing.md#paired-ci-benchmarks) |

## License

[MIT](./LICENSE)
