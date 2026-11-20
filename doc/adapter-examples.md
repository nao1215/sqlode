# Adapter examples for PostgreSQL and MySQL

The SQLite example is in the [README](../README.md#using-the-generated-adapter).

## PostgreSQL

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

## MySQL

`raw` returns the prepared SQL and encoded params; `native` generates a `mysql_adapter` that wraps `shork`.

### Raw mode

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

### Native mode

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
