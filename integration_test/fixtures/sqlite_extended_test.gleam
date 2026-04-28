import db/params
import db/sqlight_adapter
import gleam/option.{None, Some}
import gleeunit
import sqlight

pub fn main() {
  gleeunit.main()
}

// Helper: create both tables in the in-memory database
fn setup_db() -> sqlight.Connection {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE authors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        bio TEXT
      );
      CREATE TABLE posts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        author_id INTEGER NOT NULL REFERENCES authors(id)
      );",
      db,
    )
  db
}

// ---- Test :execlastid ----
pub fn insert_author_execlastid_test() {
  let db = setup_db()

  // Insert first author, should get ID 1
  let assert Ok(id1) =
    sqlight_adapter.insert_author(
      db,
      params.InsertAuthorParams(name: "Alice", bio: Some("Bio A")),
    )
  let assert True = id1 == 1

  // Insert second author, should get ID 2
  let assert Ok(id2) =
    sqlight_adapter.insert_author(
      db,
      params.InsertAuthorParams(name: "Bob", bio: None),
    )
  let assert True = id2 == 2

  Nil
}

// ---- Test :execrows ----
pub fn update_author_bio_execrows_test() {
  let db = setup_db()

  // Insert two authors
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: Some("Old bio")),
    )
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Bob", bio: Some("Old bio")),
    )

  // Update one author's bio -- should affect 1 row
  let assert Ok(rows_affected) =
    sqlight_adapter.update_author_bio(
      db,
      // Issue #512: SET col = ? on a nullable column drops Option(_).
      params.UpdateAuthorBioParams(bio: "New bio", id: 1),
    )
  let assert True = rows_affected == 1

  // Update with non-existent ID -- should affect 0 rows
  let assert Ok(zero_rows) =
    sqlight_adapter.update_author_bio(
      db,
      params.UpdateAuthorBioParams(bio: "Nope", id: 999),
    )
  let assert True = zero_rows == 0

  Nil
}

// ---- Test sqlode.narg (nullable parameter) ----
pub fn update_bio_nullable_with_value_test() {
  let db = setup_db()

  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: Some("Original")),
    )

  // Update bio to a new value using narg with Some
  let assert Ok(_) =
    sqlight_adapter.update_bio_nullable(
      db,
      params.UpdateBioNullableParams(new_bio: Some("Updated"), author_id: 1),
    )

  // Verify the bio was updated
  let assert Ok(authors) = sqlight_adapter.list_authors(db)
  let assert [author] = authors
  let assert True = author.bio == Some("Updated")

  Nil
}

pub fn update_bio_nullable_to_null_test() {
  let db = setup_db()

  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: Some("Has bio")),
    )

  // Update bio to NULL using narg with None
  let assert Ok(_) =
    sqlight_adapter.update_bio_nullable(
      db,
      params.UpdateBioNullableParams(new_bio: None, author_id: 1),
    )

  // Verify bio is now None
  let assert Ok(authors) = sqlight_adapter.list_authors(db)
  let assert [author] = authors
  let assert True = author.bio == None

  Nil
}

// ---- Test sqlode.slice (WHERE IN with list param) ----
pub fn get_authors_by_ids_slice_test() {
  let db = setup_db()

  // Insert 3 authors
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: Some("A")),
    )
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Bob", bio: Some("B")),
    )
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Charlie", bio: Some("C")),
    )

  // Fetch authors with IDs 1 and 3
  let assert Ok(authors) =
    sqlight_adapter.get_authors_by_ids(
      db,
      params.GetAuthorsByIdsParams(ids: [1, 3]),
    )
  let assert True = {
    case authors {
      [a1, a2] -> a1.name == "Alice" && a2.name == "Charlie"
      _ -> False
    }
  }

  Nil
}

// ---- Test JOIN (multi-table query) ----
pub fn get_post_with_author_join_test() {
  let db = setup_db()

  // Insert an author
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: Some("Writer")),
    )

  // Insert a post
  let assert Ok(_) =
    sqlight_adapter.create_post(
      db,
      params.CreatePostParams(
        title: "Hello World",
        body: "Content here",
        author_id: 1,
      ),
    )

  // Fetch post with author via JOIN
  let assert Ok(Some(row)) =
    sqlight_adapter.get_post_with_author(
      db,
      params.GetPostWithAuthorParams(id: 1),
    )
  let assert True = row.id == 1
  let assert True = row.title == "Hello World"
  let assert True = row.body == "Content here"
  let assert True = row.name == "Alice"

  Nil
}

pub fn get_post_with_author_not_found_test() {
  let db = setup_db()

  // No posts exist, should return None
  let assert Ok(None) =
    sqlight_adapter.get_post_with_author(
      db,
      params.GetPostWithAuthorParams(id: 999),
    )

  Nil
}

// ---- Test multiple slices in one query ----
pub fn get_authors_by_ids_and_names_test() {
  let db = setup_db()

  // Insert 4 authors
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: Some("A")),
    )
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Bob", bio: Some("B")),
    )
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Charlie", bio: Some("C")),
    )
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Diana", bio: Some("D")),
    )

  // Fetch authors where id IN [1,2,3] AND name IN ["Alice", "Charlie"]
  // Should only match Alice (id=1) and Charlie (id=3)
  let assert Ok(authors) =
    sqlight_adapter.get_authors_by_ids_and_names(
      db,
      params.GetAuthorsByIdsAndNamesParams(ids: [1, 2, 3], names: [
        "Alice",
        "Charlie",
      ]),
    )
  let assert True = {
    case authors {
      [a1, a2] -> a1.name == "Alice" && a2.name == "Charlie"
      _ -> False
    }
  }

  Nil
}

// ---- Test nullable result columns ----
pub fn list_authors_nullable_bio_test() {
  let db = setup_db()

  // Insert authors with and without bio
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: Some("Has bio")),
    )
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Bob", bio: None),
    )

  // List authors -- ordered by name
  let assert Ok(authors) = sqlight_adapter.list_authors(db)
  let assert True = {
    case authors {
      [alice, bob] ->
        alice.name == "Alice"
        && alice.bio == Some("Has bio")
        && bob.name == "Bob"
        && bob.bio == None
      _ -> False
    }
  }

  Nil
}
