import db/models
import db/params
import db/sqlight_adapter
import gleam/option.{None, Some}
import gleeunit
import sqlight

pub fn main() {
  gleeunit.main()
}

// Helper: create tables in the in-memory database
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

// ---- Test COUNT expression ----
pub fn count_authors_expression_test() {
  let db = setup_db()

  // Empty table: count should be 0
  let assert Ok(Some(row)) = sqlight_adapter.count_authors(db)
  let assert True = row.total == 0

  // Add two authors
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: Some("Bio")),
    )
  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Bob", bio: None),
    )

  // Count should be 2
  let assert Ok(Some(row2)) = sqlight_adapter.count_authors(db)
  let assert True = row2.total == 2

  Nil
}

// ---- Test COALESCE expression ----
pub fn coalesce_author_bio_test() {
  let db = setup_db()

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

  let assert Ok(rows) = sqlight_adapter.coalesce_author_bio(db)
  let assert True = {
    case rows {
      [r1, r2] -> r1.bio_text == "Has bio" && r2.bio_text == "N/A"
      _ -> False
    }
  }

  Nil
}

// ---- Test LEFT JOIN with null result ----
pub fn left_join_with_null_author_test() {
  let db = setup_db()

  // Create a post with author_id = 999 (no matching author)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO posts (title, body, author_id) VALUES ('Orphan', 'Body', 999);",
      db,
    )

  let assert Ok(Some(row)) =
    sqlight_adapter.get_post_with_author_left_join(
      db,
      params.GetPostWithAuthorLeftJoinParams(id: 1),
    )
  let assert True = row.title == "Orphan"
  // author_name should be None since no author matches
  let assert True = row.author_name == None

  Nil
}

// ---- Test LEFT JOIN with valid author ----
pub fn left_join_with_valid_author_test() {
  let db = setup_db()

  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: None),
    )
  let assert Ok(_) =
    sqlight_adapter.create_post(
      db,
      params.CreatePostParams(title: "Hello", body: "World", author_id: 1),
    )

  let assert Ok(Some(row)) =
    sqlight_adapter.get_post_with_author_left_join(
      db,
      params.GetPostWithAuthorLeftJoinParams(id: 1),
    )
  let assert True = row.title == "Hello"
  let assert True = row.author_name == Some("Alice")

  Nil
}

// ---- Test sqlode.embed() runtime ----
pub fn sqlode_embed_returns_nested_row_test() {
  let db = setup_db()

  let assert Ok(_) =
    sqlight_adapter.create_author(
      db,
      params.CreateAuthorParams(name: "Alice", bio: Some("Author bio")),
    )
  let assert Ok(_) =
    sqlight_adapter.create_post(
      db,
      params.CreatePostParams(
        title: "Hello World",
        body: "body text",
        author_id: 1,
      ),
    )

  let assert Ok(Some(row)) =
    sqlight_adapter.get_post_with_author_embed(
      db,
      params.GetPostWithAuthorEmbedParams(id: 1),
    )
  let assert True = row.title == "Hello World"
  let assert models.Author(id: 1, name: "Alice", bio: Some("Author bio")) =
    row.authors

  Nil
}
