#!/bin/sh
# shellcheck shell=sh

Describe 'generated code compilation'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  INTEGRATION_DIR="$PROJECT_ROOT/test_integration_tmp"

  setup_raw_project() {
    rm -rf "$INTEGRATION_DIR"
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
  }

  setup_sqlight_project() {
    rm -rf "$INTEGRATION_DIR"
    mkdir -p "$INTEGRATION_DIR/src/db"

    cat > "$INTEGRATION_DIR/gleam.toml" << TOML
name = "integration_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
sqlight = ">= 1.0.0 and < 2.0.0"
sqlode = { path = "$PROJECT_ROOT" }
TOML

    cat > "$INTEGRATION_DIR/sqlode.yaml" << YAML
version: "2"
sql:
  - schema: "$PROJECT_ROOT/test/fixtures/schema.sql"
    queries: "$PROJECT_ROOT/test/fixtures/query.sql"
    engine: "sqlite"
    gen:
      gleam:
        package: "db"
        out: "$INTEGRATION_DIR/src/db"
        runtime: "native"
YAML
  }

  cleanup_project() {
    rm -rf "$INTEGRATION_DIR"
  }

  generate_and_build() {
    cd "$PROJECT_ROOT" && gleam run -- generate --config="$INTEGRATION_DIR/sqlode.yaml" 2>&1
    cd "$INTEGRATION_DIR" && gleam build 2>&1
  }

  Describe 'raw mode (params + queries + models)'
    Before 'setup_raw_project'
    After 'cleanup_project'

    It 'generates and builds raw mode code'
      When call generate_and_build
      The status should be success
      The output should include 'Successfully generated'
      The output should include 'Compiled in'
    End
  End

  Describe 'SQLite native mode (with sqlight adapter)'
    Before 'setup_sqlight_project'
    After 'cleanup_project'

    It 'generates and builds SQLite native mode code'
      When call generate_and_build
      The status should be success
      The output should include 'Successfully generated'
      The output should include 'Compiled in'
    End
  End
End
