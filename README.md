# sqlode

[![license](https://img.shields.io/github/license/nao1215/sqlode)](./LICENSE)

sqlode reads SQL schema and query files, then generates typed Gleam code. The workflow follows [sqlc](https://sqlc.dev/) conventions: write SQL, run the generator, get type-safe functions.

Supported engines: PostgreSQL, MySQL, SQLite.

## Getting started

### Install

```console
gleam add sqlode
```

### Initialize config

```console
sqlode init
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
sqlode generate
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
sqlode generate [--config=./sqlode.yaml]
sqlode init [--output=./sqlode.yaml]
```

## License

[MIT](./LICENSE)
