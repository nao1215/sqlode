#!/bin/sh
# Integration test: verify generated Gleam code compiles
# This test creates a temporary Gleam project, generates code into it,
# and runs gleam build to verify the generated code is syntactically valid.

set -eu

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT
INTEGRATION_DIR="$PROJECT_ROOT/test_integration_tmp"

# shellcheck source=integration_test/lib.sh
. "$PROJECT_ROOT/integration_test/lib.sh"

cleanup() {
  integration_clean "$INTEGRATION_DIR"
}
trap cleanup EXIT

run_case() {
  label="$1"
  schema_path="$2"
  queries_path="$3"

  echo ""
  echo "--- $label ---"

  cleanup
  integration_write_project \
    --dir "$INTEGRATION_DIR" \
    --engine postgresql \
    --runtime raw \
    --schema "$schema_path" \
    --queries "$queries_path"

  echo "Generating code..."
  integration_generate "$INTEGRATION_DIR"

  echo "Building generated project..."
  integration_build "$INTEGRATION_DIR"

  echo "PASS: $label"
}

echo "=== Integration test: generated code compilation ==="

run_case "raw mode" \
  "$PROJECT_ROOT/test/fixtures/schema.sql" \
  "$PROJECT_ROOT/test/fixtures/query.sql"

run_case "raw mode with complex schema" \
  "$PROJECT_ROOT/test/fixtures/complex_schema.sql" \
  "$PROJECT_ROOT/test/fixtures/complex_query.sql"

run_case "raw mode with all types" \
  "$PROJECT_ROOT/test/fixtures/all_types_schema.sql" \
  "$PROJECT_ROOT/test/fixtures/all_types_query.sql"

echo ""
echo "=== All integration tests passed ==="
