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

echo "=== Integration test: generated code compilation ==="

# --- Test 1: raw mode (params + queries + models) ---
echo ""
echo "--- Test 1: raw mode ---"

cleanup
mkdir -p "$INTEGRATION_DIR/src/db"

cat > "$INTEGRATION_DIR/gleam.toml" << TOML
name = "integration_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
sqlode = { path = "$PROJECT_ROOT" }
TOML

cat > "$INTEGRATION_DIR/sqlode.yaml" << YAML
version: "2"
sql:
  - schema: "$PROJECT_ROOT/test/fixtures/schema.sql"
    queries: "$PROJECT_ROOT/test/fixtures/query.sql"
    engine: "postgresql"
    gen:
      gleam:
        package: "db"
        out: "$INTEGRATION_DIR/src/db"
        runtime: "raw"
YAML

echo "Generating code..."
cd "$PROJECT_ROOT"
gleam run -- generate --config="$INTEGRATION_DIR/sqlode.yaml"

echo "Building generated project..."
cd "$INTEGRATION_DIR"
gleam build

echo "PASS: raw mode code compiles"

# --- Test 2: raw mode with complex schema ---
echo ""
echo "--- Test 2: raw mode with complex schema ---"

cleanup
mkdir -p "$INTEGRATION_DIR/src/db"

cat > "$INTEGRATION_DIR/gleam.toml" << TOML
name = "integration_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
sqlode = { path = "$PROJECT_ROOT" }
TOML

cat > "$INTEGRATION_DIR/sqlode.yaml" << YAML
version: "2"
sql:
  - schema: "$PROJECT_ROOT/test/fixtures/complex_schema.sql"
    queries: "$PROJECT_ROOT/test/fixtures/complex_query.sql"
    engine: "postgresql"
    gen:
      gleam:
        package: "db"
        out: "$INTEGRATION_DIR/src/db"
        runtime: "raw"
YAML

echo "Generating code..."
cd "$PROJECT_ROOT"
gleam run -- generate --config="$INTEGRATION_DIR/sqlode.yaml"

echo "Building generated project..."
cd "$INTEGRATION_DIR"
gleam build

echo "PASS: complex schema raw mode code compiles"

# --- Test 3: raw mode with all types ---
echo ""
echo "--- Test 3: raw mode with all types ---"

cleanup
mkdir -p "$INTEGRATION_DIR/src/db"

cat > "$INTEGRATION_DIR/gleam.toml" << TOML
name = "integration_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
sqlode = { path = "$PROJECT_ROOT" }
TOML

cat > "$INTEGRATION_DIR/sqlode.yaml" << YAML
version: "2"
sql:
  - schema: "$PROJECT_ROOT/test/fixtures/all_types_schema.sql"
    queries: "$PROJECT_ROOT/test/fixtures/all_types_query.sql"
    engine: "postgresql"
    gen:
      gleam:
        package: "db"
        out: "$INTEGRATION_DIR/src/db"
        runtime: "raw"
YAML

echo "Generating code..."
cd "$PROJECT_ROOT"
gleam run -- generate --config="$INTEGRATION_DIR/sqlode.yaml"

echo "Building generated project..."
cd "$INTEGRATION_DIR"
gleam build

echo "PASS: all types raw mode code compiles"

echo ""
echo "=== All integration tests passed ==="
