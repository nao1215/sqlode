# sqlode

[![license](https://img.shields.io/github/license/nao1215/sqlode)](./LICENSE)

sqlode reads SQL schema and query files, then generates typed Gleam code. The workflow follows [sqlc](https://sqlc.dev/) conventions: write SQL, run the generator, get type-safe functions.

Supported engines: PostgreSQL, MySQL (parsing only), SQLite.

## Getting started

### Install

There are two ways to install sqlode:

#### Option A: Standalone CLI (escript)

Download the pre-built escript from [GitHub Releases](https://github.com/nao1215/sqlode/releases) and place it on your PATH. Requires Erlang/OTP runtime on the host machine.

```console
chmod +x sqlode
./sqlode generate --config=sqlode.yaml
```

You still need sqlode as a project dependency because generated code imports `sqlode/runtime`:

```console
gleam add sqlode
```

#### Option B: Run via Gleam

Add sqlode as a dependency and invoke the CLI through `gleam run`:

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

This creates `sqlode.yaml`:

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
```

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
VALUES (sqlc.arg(author_name), sqlc.narg(bio));
```

### Generate

```console
# standalone CLI
sqlode generate

# or via Gleam
gleam run -m sqlode -- generate
```

This produces `params.gleam` and `queries.gleam` in the configured output directory. `models.gleam` is also generated when at least one query uses `:one` or `:many` and returns result columns.

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

```gleam
pub type GetAuthorRow {
  GetAuthorRow(id: Int, name: String, bio: Option(String))
}

pub type ListAuthorsRow {
  ListAuthorsRow(id: Int, name: String)
}
```

### queries.gleam

```gleam
pub type Query {
  Query(name: String, sql: String, command: runtime.QueryCommand, param_count: Int)
}

pub fn get_author() -> Query { ... }
pub fn list_authors() -> Query { ... }
pub fn create_author() -> Query { ... }
```

## Runtime modes

The `runtime` option controls what code sqlode generates and what dependencies your project needs.

| Mode | Generated files | DB driver needed | Use case |
|------|----------------|-----------------|----------|
| `raw` | queries, params, models | No | You handle database interaction yourself |
| `native` | queries, params, models, adapter | Yes (pog/sqlight) | Full adapter with parameter binding and result decoding |

> **Note:** `runtime: "based"` is reserved for future use and is currently rejected. Use `"raw"` or `"native"` instead.

**Dependency note:** In all modes, sqlode must be a dependency (not just a dev-dependency) because the generated code imports `sqlode/runtime` for the `Value` type and `QueryCommand` type. The `native` adapter mode additionally requires a database driver package:

```console
gleam add sqlode
gleam add pog       # for PostgreSQL with native runtime
gleam add sqlight   # for SQLite with native runtime
```

## Adapter generation

When `runtime` is set to `native`, sqlode generates adapter modules that wrap [pog](https://hexdocs.pm/pog/) (PostgreSQL) or [sqlight](https://hexdocs.pm/sqlight/) (SQLite).

**Note:** MySQL adapter generation is not yet available. MySQL schema parsing and query/params generation work with `runtime: "raw"`. Configuring MySQL with `runtime: "native"` is rejected at config validation time — use `runtime: "raw"` and handle database interaction manually.

```yaml
gen:
  gleam:
    package: "db"
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

## Query annotations

| Annotation | Description |
|---|---|
| `:one` | Returns at most one row |
| `:many` | Returns zero or more rows |
| `:exec` | Returns nothing |
| `:execresult` | Returns the execution result |
| `:execrows` | Returns the number of affected rows |
| `:execlastid` | Returns the last inserted ID |

## sqlc macros

| Macro | Description |
|---|---|
| `sqlc.arg(name)` | Names a parameter |
| `sqlc.narg(name)` | Names a nullable parameter |
| `sqlc.slice(name)` | Expands to a list parameter for IN clauses |
| `sqlc.embed(table)` | Embeds all columns of a table into the result |

### sqlc.slice example

```sql
-- name: GetAuthorsByIds :many
SELECT id, name FROM authors
WHERE id IN (sqlc.slice(ids));
```

Generates a parameter with type `List(Int)`:

```gleam
pub type GetAuthorsByIdsParams {
  GetAuthorsByIdsParams(ids: List(Int))
}
```

### sqlc.embed example

```sql
-- name: GetBookWithAuthor :one
SELECT sqlc.embed(authors), books.title
FROM books
JOIN authors ON books.author_id = authors.id
WHERE books.id = $1;
```

The result type includes all columns from the `authors` table followed by `title`:

```gleam
pub type GetBookWithAuthorRow {
  GetBookWithAuthorRow(id: Int, name: String, bio: Option(String), title: String)
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
| INT, INTEGER, BIGINT, SERIAL, BIGSERIAL | Int |
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

## Overrides

Type overrides and column renames can be configured per SQL block:

```yaml
sql:
  - schema: "db/schema.sql"
    queries: "db/query.sql"
    engine: "postgresql"
    gen:
      gleam:
        package: "db"
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
| Config | `sqlc.yaml` / `sqlc.json` | `sqlode.yaml` (v2 format only) |
| Generate | `sqlc generate` | `sqlode generate` |
| Init | `sqlc init` | `sqlode init` |
| Vet/Verify | `sqlc vet`, `sqlc verify` | Not supported |
| Target language | Go, Python, Kotlin, etc. | Gleam |
| Runtime | Generated code is self-contained | Generated code imports `sqlode/runtime` |

### Migration steps

1. Install sqlode (see [Install](#install) above).
2. Copy your `sqlc.yaml` to `sqlode.yaml`. Keep `version: "2"` and the `sql` blocks. Replace the `gen` section:

   ```yaml
   gen:
     gleam:
       package: "db"
       out: "src/db"
       runtime: "raw"   # or "native" for full adapter generation
   ```

3. Your existing `.sql` schema and query files should work as-is. sqlode supports `sqlc.arg()`, `sqlc.narg()`, `sqlc.slice()`, `sqlc.embed()`, and `@name` shorthand.

4. Run `sqlode generate` (or `gleam run -m sqlode -- generate`).

### Unsupported sqlc features

- `sqlc.yaml` v1 format
- `vet` and `verify` commands
- `emit_*` options (`emit_exact_table_names`, `emit_json_tags`, etc.)
- Batch annotations (`:batchexec`, `:batchmany`, `:batchone`)
- `:copyfrom` annotation
- MySQL adapter generation (`runtime: "raw"` works for MySQL)

## License

[MIT](./LICENSE)
