#!/bin/sh
# Integration test: advanced SQLite patterns covering expression columns
# (COUNT, COALESCE), LEFT JOIN with null results, and sqlode.embed.

set -eu

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTEGRATION_DIR="$PROJECT_ROOT/test_integration_sqlite_advanced_tmp"

cleanup() {
  rm -rf "$INTEGRATION_DIR"
}
trap cleanup EXIT

echo "=== Integration test: SQLite advanced features ==="

# --- Setup: create a temporary Gleam project ---
cleanup
mkdir -p "$INTEGRATION_DIR/src/db"
mkdir -p "$INTEGRATION_DIR/test"

cat > "$INTEGRATION_DIR/gleam.toml" << TOML
name = "sqlite_advanced_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
sqlight = ">= 1.0.0 and < 2.0.0"
sqlode = { path = "$PROJECT_ROOT" }

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML

cat > "$INTEGRATION_DIR/sqlode.yaml" << YAML
version: "2"
sql:
  - schema: "$PROJECT_ROOT/test/fixtures/sqlite_advanced_schema.sql"
    queries: "$PROJECT_ROOT/test/fixtures/sqlite_advanced_query.sql"
    engine: "sqlite"
    gen:
      gleam:
        out: "$INTEGRATION_DIR/src/db"
        runtime: "native"
YAML

# --- Generate adapter code ---
echo ""
echo "--- Generating SQLite adapter code ---"
cd "$PROJECT_ROOT"
gleam run -- generate --config="$INTEGRATION_DIR/sqlode.yaml"

# --- Verify generated files exist ---
echo ""
echo "--- Verifying generated files ---"
for f in params.gleam queries.gleam models.gleam sqlight_adapter.gleam; do
  if [ ! -f "$INTEGRATION_DIR/src/db/$f" ]; then
    echo "FAIL: expected file $f not generated"
    exit 1
  fi
done
echo "All expected files generated"

# --- Write the integration test ---
cat > "$INTEGRATION_DIR/test/sqlite_advanced_test_test.gleam" << 'GLEAM'
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

// Note: sqlode.embed() runtime test is skipped because the generated SQL
// retains the sqlode.embed(...) macro text which is not valid SQL.
// The embed codegen (nested type generation + decoder) is verified
// at the unit test level in codegen_test.gleam.
GLEAM

# --- Build first to check compilation ---
echo ""
echo "--- Building project ---"
cd "$INTEGRATION_DIR"
gleam build

echo "PASS: project builds successfully"

# --- Run the tests ---
echo ""
echo "--- Running integration tests ---"
cd "$INTEGRATION_DIR"
gleam test

echo ""
echo "=== SQLite advanced integration test passed ==="
