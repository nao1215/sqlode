#!/bin/sh
# Integration test: verify generated SQLite adapter code works against a real database
# This test creates a temporary Gleam project, generates adapter code,
# then runs tests that exercise the generated code against an in-memory SQLite DB.

set -eu

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT
INTEGRATION_DIR="$PROJECT_ROOT/test_integration_sqlite_tmp"

# shellcheck source=integration_test/lib.sh
. "$PROJECT_ROOT/integration_test/lib.sh"

cleanup() {
  integration_clean "$INTEGRATION_DIR"
}
trap cleanup EXIT

echo "=== Integration test: SQLite real database ==="

cleanup
integration_write_project \
  --dir "$INTEGRATION_DIR" \
  --name sqlite_integration_test \
  --engine sqlite \
  --runtime native \
  --schema "$PROJECT_ROOT/test/fixtures/sqlite_schema.sql" \
  --queries "$PROJECT_ROOT/test/fixtures/sqlite_crud_query.sql" \
  --dev-deps gleeunit
mkdir -p "$INTEGRATION_DIR/test"

echo ""
echo "--- Generating SQLite adapter code ---"
integration_generate "$INTEGRATION_DIR"

echo ""
echo "--- Verifying generated files ---"
for f in params.gleam queries.gleam models.gleam sqlight_adapter.gleam; do
  if [ ! -f "$INTEGRATION_DIR/src/db/$f" ]; then
    echo "FAIL: expected file $f not generated"
    exit 1
  fi
done
echo "All expected files generated"

cp "$PROJECT_ROOT/integration_test/fixtures/sqlite_basic_test.gleam" \
   "$INTEGRATION_DIR/test/sqlite_integration_test_test.gleam"

echo ""
echo "--- Building project ---"
integration_build "$INTEGRATION_DIR"

echo "PASS: project builds successfully"

echo ""
echo "--- Running integration tests ---"
integration_test "$INTEGRATION_DIR"

echo ""
echo "=== SQLite integration test passed ==="
