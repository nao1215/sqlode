import db/params
import db/sqlight_adapter
import gleam/option
import gleeunit
import sqlight

pub fn main() {
  gleeunit.main()
}

pub fn create_and_get_author_test() {
  let assert Ok(db) = sqlight.open(":memory:")

  // Create the table
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE authors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        bio TEXT
      );",
      db,
    )

  // Insert an author
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: option.Some("A bio")),
    )

  // Get the author by ID
  let assert Ok(option.Some(author)) =
    sqlight_adapter.get_author(db, params.GetAuthorParams(id: 1))
  let assert True = author.id == 1
  let assert True = author.name == "Alice"
  let assert True = author.bio == option.Some("A bio")

  Nil
}

pub fn list_authors_test() {
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

  // Insert multiple authors
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Bob", bio: option.Some("Bio B")),
    )
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: option.Some("Bio A")),
    )

  // List authors (ordered by name)
  let assert Ok(authors) = sqlight_adapter.list_authors(db)
  let assert True = {
    case authors {
      [first, second] -> first.name == "Alice" && second.name == "Bob"
      _ -> False
    }
  }

  Nil
}

pub fn create_author_with_null_bio_test() {
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

  // Insert an author with NULL bio
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "NoBio", bio: option.None),
    )

  // Get the author and verify bio is None
  let assert Ok(option.Some(author)) =
    sqlight_adapter.get_author(db, params.GetAuthorParams(id: 1))
  let assert True = author.name == "NoBio"
  let assert True = author.bio == option.None

  Nil
}

pub fn get_nonexistent_author_test() {
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

  // Get a non-existent author returns None
  let assert Ok(option.None) =
    sqlight_adapter.get_author(db, params.GetAuthorParams(id: 999))

  Nil
}

pub fn delete_author_test() {
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

  // Insert then delete
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Charlie", bio: option.Some("Bio C")),
    )

  let assert Ok(_) =
    sqlight_adapter.delete_author(db, params.DeleteAuthorParams(id: 1))

  // Verify deleted
  let assert Ok(option.None) =
    sqlight_adapter.get_author(db, params.GetAuthorParams(id: 1))

  Nil
}
