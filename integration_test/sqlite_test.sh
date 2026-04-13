#!/bin/sh
# Integration test: verify generated SQLite adapter code works against a real database
# This test creates a temporary Gleam project, generates adapter code,
# then runs tests that exercise the generated code against an in-memory SQLite DB.

set -eu

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTEGRATION_DIR="$PROJECT_ROOT/test_integration_sqlite_tmp"

cleanup() {
  rm -rf "$INTEGRATION_DIR"
}
trap cleanup EXIT

echo "=== Integration test: SQLite real database ==="

# --- Setup: create a temporary Gleam project ---
cleanup
mkdir -p "$INTEGRATION_DIR/src/db"
mkdir -p "$INTEGRATION_DIR/test"

cat > "$INTEGRATION_DIR/gleam.toml" << TOML
name = "sqlite_integration_test"
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
  - schema: "$PROJECT_ROOT/test/fixtures/sqlite_schema.sql"
    queries: "$PROJECT_ROOT/test/fixtures/sqlite_crud_query.sql"
    engine: "sqlite"
    gen:
      gleam:
        package: "db"
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
cat > "$INTEGRATION_DIR/test/sqlite_integration_test_test.gleam" << 'GLEAM'
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
echo "=== SQLite integration test passed ==="
