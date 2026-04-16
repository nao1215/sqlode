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

# --- Copy the integration test module from tracked fixture ---
cp "$PROJECT_ROOT/integration_test/fixtures/sqlite_basic_test.gleam" \
   "$INTEGRATION_DIR/test/sqlite_integration_test_test.gleam"

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
