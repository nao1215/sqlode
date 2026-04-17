#!/bin/sh
# Integration test: verify generated Gleam code compiles
# This test creates a temporary Gleam project, generates code into it,
# and runs gleam build to verify the generated code is syntactically valid.

set -eu

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTEGRATION_DIR="$PROJECT_ROOT/test_integration_tmp"

cleanup() {
  rm -rf "$INTEGRATION_DIR"
}
trap cleanup EXIT

# Render the per-case gleam.toml and sqlode.yaml from tracked templates.
# Templates live under integration_test/fixtures/ and use placeholders
# {{PROJECT_ROOT}} / {{INTEGRATION_DIR}} / {{SCHEMA}} / {{QUERIES}} that
# this function substitutes via sed.
render_project() {
  schema_path="$1"
  queries_path="$2"

  mkdir -p "$INTEGRATION_DIR/src/db"

  sed \
    -e "s|{{PROJECT_ROOT}}|$PROJECT_ROOT|g" \
    "$PROJECT_ROOT/integration_test/fixtures/compile_test_gleam.toml.tmpl" \
    > "$INTEGRATION_DIR/gleam.toml"

  sed \
    -e "s|{{PROJECT_ROOT}}|$PROJECT_ROOT|g" \
    -e "s|{{INTEGRATION_DIR}}|$INTEGRATION_DIR|g" \
    -e "s|{{SCHEMA}}|$schema_path|g" \
    -e "s|{{QUERIES}}|$queries_path|g" \
    "$PROJECT_ROOT/integration_test/fixtures/compile_test_sqlode.yaml.tmpl" \
    > "$INTEGRATION_DIR/sqlode.yaml"
}

run_case() {
  label="$1"
  schema_path="$2"
  queries_path="$3"

  echo ""
  echo "--- $label ---"

  cleanup
  render_project "$schema_path" "$queries_path"

  echo "Generating code..."
  cd "$PROJECT_ROOT"
  gleam run -- generate --config="$INTEGRATION_DIR/sqlode.yaml"

  echo "Building generated project..."
  cd "$INTEGRATION_DIR"
  gleam build

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
