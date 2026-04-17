#!/bin/sh
# Integration test: extended SQLite adapter tests covering execrows, execlastid,
# narg, slice, JOINs, multiple slices, and nullable result columns.

set -eu

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT
INTEGRATION_DIR="$PROJECT_ROOT/test_integration_sqlite_extended_tmp"

# shellcheck source=integration_test/lib.sh
. "$PROJECT_ROOT/integration_test/lib.sh"

cleanup() {
  integration_clean "$INTEGRATION_DIR"
}
trap cleanup EXIT

echo "=== Integration test: SQLite extended features ==="

cleanup
integration_write_project \
  --dir "$INTEGRATION_DIR" \
  --name sqlite_extended_test \
  --engine sqlite \
  --runtime native \
  --schema "$PROJECT_ROOT/test/fixtures/sqlite_extended_schema.sql" \
  --queries "$PROJECT_ROOT/test/fixtures/sqlite_extended_query.sql" \
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

cp "$PROJECT_ROOT/integration_test/fixtures/sqlite_extended_test.gleam" \
   "$INTEGRATION_DIR/test/sqlite_extended_test_test.gleam"

echo ""
echo "--- Building project ---"
integration_build "$INTEGRATION_DIR"

echo "PASS: project builds successfully"

echo ""
echo "--- Running integration tests ---"
integration_test "$INTEGRATION_DIR"

echo ""
echo "=== SQLite extended integration test passed ==="
