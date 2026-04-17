#!/bin/sh
# shellcheck shell=sh

Describe 'generated code compilation'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"
  # shellcheck source=integration_test/lib.sh
  Include "$PROJECT_ROOT/integration_test/lib.sh"

  INTEGRATION_DIR="$PROJECT_ROOT/test_integration_tmp"
  SCHEMA="$PROJECT_ROOT/test/fixtures/schema.sql"
  QUERIES="$PROJECT_ROOT/test/fixtures/query.sql"

  setup_raw_project() {
    integration_clean "$INTEGRATION_DIR"
    integration_write_project \
      --dir "$INTEGRATION_DIR" \
      --engine postgresql \
      --runtime raw \
      --schema "$SCHEMA" \
      --queries "$QUERIES"
  }

  setup_sqlight_project() {
    integration_clean "$INTEGRATION_DIR"
    integration_write_project \
      --dir "$INTEGRATION_DIR" \
      --engine sqlite \
      --runtime native \
      --schema "$SCHEMA" \
      --queries "$QUERIES"
  }

  setup_pog_project() {
    integration_clean "$INTEGRATION_DIR"
    integration_write_project \
      --dir "$INTEGRATION_DIR" \
      --engine postgresql \
      --runtime native \
      --schema "$SCHEMA" \
      --queries "$QUERIES"
  }

  setup_mysql_raw_project() {
    integration_clean "$INTEGRATION_DIR"
    integration_write_project \
      --dir "$INTEGRATION_DIR" \
      --engine mysql \
      --runtime raw \
      --schema "$PROJECT_ROOT/test/fixtures/mysql_schema.sql" \
      --queries "$PROJECT_ROOT/test/fixtures/mysql_query.sql"
  }

  setup_all_commands_sqlight_project() {
    integration_clean "$INTEGRATION_DIR"
    integration_write_project \
      --dir "$INTEGRATION_DIR" \
      --engine sqlite \
      --runtime native \
      --schema "$PROJECT_ROOT/test/fixtures/all_commands_schema.sql" \
      --queries "$PROJECT_ROOT/test/fixtures/all_commands_query.sql"
  }

  cleanup_project() {
    integration_clean "$INTEGRATION_DIR"
  }

  generate_and_build() {
    integration_generate "$INTEGRATION_DIR" 2>&1
    integration_build "$INTEGRATION_DIR" 2>&1
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

  Describe 'PostgreSQL native mode (with pog adapter)'
    Before 'setup_pog_project'
    After 'cleanup_project'

    It 'generates and builds PostgreSQL native mode code'
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

  Describe 'all 6 command types (sqlight adapter)'
    Before 'setup_all_commands_sqlight_project'
    After 'cleanup_project'

    It 'generates and builds code for all query command types'
      When call generate_and_build
      The status should be success
      The output should include 'Successfully generated'
      The output should include 'Compiled in'
    End
  End

  Describe 'MySQL raw mode (backtick identifiers and ? placeholders)'
    Before 'setup_mysql_raw_project'
    After 'cleanup_project'

    It 'generates and builds MySQL raw mode code'
      When call generate_and_build
      The status should be success
      The output should include 'Successfully generated'
      The output should include 'Compiled in'
    End
  End
End
