# sqlode

[![license](https://img.shields.io/github/license/nao1215/sqlode)](./LICENSE)

sqlode reads SQL schema and query files, then generates typed Gleam code. The workflow follows [sqlc](https://sqlc.dev/) conventions: write SQL, run the generator, get type-safe functions.

Supported engines: PostgreSQL, MySQL (parsing only), SQLite.

## Getting started

### Install

Add sqlode as a development dependency:

```console
gleam add --dev sqlode
```

### Initialize config

```console
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
gleam run -m sqlode -- generate
```

This produces `params.gleam`, `queries.gleam`, and `models.gleam` in the configured output directory.

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

## Adapter generation

When `runtime` is set to `native` or `based`, sqlode generates adapter modules that wrap [pog](https://hexdocs.pm/pog/) (PostgreSQL) or [sqlight](https://hexdocs.pm/sqlight/) (SQLite).

**Note:** MySQL adapter generation is not yet available. MySQL schema parsing and query/params generation work, but `runtime: "native"` will produce a stub adapter. Use `runtime: "raw"` with MySQL and handle database interaction manually.

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
      renames:
        - table: "authors"
          column: "bio"
          rename_to: "biography"
```

## CLI

```
gleam run -m sqlode -- generate [--config=./sqlode.yaml]
gleam run -m sqlode -- init [--output=./sqlode.yaml]
```

## License

[MIT](./LICENSE)
