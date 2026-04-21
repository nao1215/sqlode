//// End-to-end test against a real in-memory SQLite database.
////
//// Requires `sqlode generate` to have been run first so that the
//// generated modules under `src/db/` exist.

import db/params
import db/sqlight_adapter
import gleam/option
import gleeunit
import sqlight

pub fn main() {
  gleeunit.main()
}

fn open_with_schema() -> sqlight.Connection {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE authors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        bio TEXT
      );",
      db,
    )
  db
}

pub fn create_and_get_author_test() {
  let db = open_with_schema()

  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: option.Some("A bio")),
    )

  let assert Ok(option.Some(author)) =
    sqlight_adapter.get_author(db, params.GetAuthorParams(id: 1))
  let assert True = author.id == 1
  let assert True = author.name == "Alice"
  let assert True = author.bio == option.Some("A bio")

  Nil
}

pub fn list_authors_is_ordered_by_name_test() {
  let db = open_with_schema()

  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Bob", bio: option.None),
    )
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: option.None),
    )

  let assert Ok([first, second]) = sqlight_adapter.list_authors(db)
  let assert True = first.name == "Alice"
  let assert True = second.name == "Bob"

  Nil
}
