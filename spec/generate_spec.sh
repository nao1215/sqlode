#!/bin/sh
# shellcheck shell=sh

Describe 'sqlode generate'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  Describe 'CLI help'
    It 'shows generate usage'
      When run generate --help
      The status should be success
      The output should include 'generate'
      The output should include 'config'
      The output should include 'auto-discover'
    End
  End

  Describe 'error handling'
    It 'fails when config file does not exist'
      When run generate --config=missing.yaml
      The status should be failure
      The output should include 'Config file not found'
    End
  End

  Describe 'successful generation'
    Before 'clean_test_output'
    After 'clean_test_output'

    It 'generates params, queries, and models from sqlc style input'
      When run generate --config=test/fixtures/sqlode.yaml
      The status should be success
      The output should include 'Successfully generated 3 files'
      The path "$TEST_OUTPUT_DIR/db/params.gleam" should be file
      The path "$TEST_OUTPUT_DIR/db/queries.gleam" should be file
      The path "$TEST_OUTPUT_DIR/db/models.gleam" should be file
      The contents of file "$TEST_OUTPUT_DIR/db/params.gleam" should include 'GetAuthorParams(id: Int)'
      The contents of file "$TEST_OUTPUT_DIR/db/params.gleam" should include 'runtime.int(params.id)'
      The contents of file "$TEST_OUTPUT_DIR/db/queries.gleam" should include 'pub fn get_author() -> runtime.RawQuery(params.GetAuthorParams) {'
      The contents of file "$TEST_OUTPUT_DIR/db/queries.gleam" should include 'pub fn list_authors() -> runtime.RawQuery(Nil) {'
      The contents of file "$TEST_OUTPUT_DIR/db/models.gleam" should include 'pub type GetAuthorRow {'
      The contents of file "$TEST_OUTPUT_DIR/db/models.gleam" should include 'pub type ListAuthorsRow {'
    End
  End

  Describe 'config autodiscovery'
    AUTODISCOVER_DIR="$PROJECT_ROOT/test_output/autodiscover"

    setup_autodiscover_dir() {
      rm -rf "$AUTODISCOVER_DIR"
      mkdir -p "$AUTODISCOVER_DIR"
    }

    write_config() {
      name="$1"
      cat > "$AUTODISCOVER_DIR/$name" <<YAML
version: "2"
sql:
  - schema: "$PROJECT_ROOT/test/fixtures/schema.sql"
    queries: "$PROJECT_ROOT/test/fixtures/query.sql"
    engine: "postgresql"
    gen:
      gleam:
        out: "$AUTODISCOVER_DIR/src/db"
        runtime: "raw"
YAML
    }

    generate_in_dir() {
      cd "$AUTODISCOVER_DIR" && gleam run --module=sqlode -- generate 2>&1
    }

    generate_from_autodiscover_dir() {
      cd "$PROJECT_ROOT" && gleam export erlang-shipment >/dev/null 2>&1
      cd "$AUTODISCOVER_DIR" && "$PROJECT_ROOT/build/erlang-shipment/entrypoint.sh" run generate 2>&1
    }

    cleanup_autodiscover_dir() {
      rm -rf "$AUTODISCOVER_DIR"
    }

    It 'fails with a helpful message when no config file exists'
      setup_autodiscover_dir
      When call generate_from_autodiscover_dir
      The status should be failure
      The output should include 'No config file found'
      The output should include 'sqlode.yaml'
      The output should include 'sqlc.json'
      cleanup_autodiscover_dir
    End

    It 'picks up sqlode.yaml without --config'
      setup_autodiscover_dir
      write_config sqlode.yaml
      When call generate_from_autodiscover_dir
      The status should be success
      The output should include 'Loading config from: sqlode.yaml'
      The output should include 'Successfully generated'
      cleanup_autodiscover_dir
    End

    It 'falls back to sqlc.yaml when sqlode.yaml is absent'
      setup_autodiscover_dir
      write_config sqlc.yaml
      When call generate_from_autodiscover_dir
      The status should be success
      The output should include 'Loading config from: sqlc.yaml'
      The output should include 'Successfully generated'
      cleanup_autodiscover_dir
    End

    It 'falls back to sqlc.json when only JSON is present'
      setup_autodiscover_dir
      cat > "$AUTODISCOVER_DIR/sqlc.json" <<JSON
{
  "version": "2",
  "sql": [
    {
      "schema": "$PROJECT_ROOT/test/fixtures/schema.sql",
      "queries": "$PROJECT_ROOT/test/fixtures/query.sql",
      "engine": "postgresql",
      "gen": {"gleam": {"out": "$AUTODISCOVER_DIR/src/db", "runtime": "raw"}}
    }
  ]
}
JSON
      When call generate_from_autodiscover_dir
      The status should be success
      The output should include 'Loading config from: sqlc.json'
      The output should include 'Successfully generated'
      cleanup_autodiscover_dir
    End

    It 'refuses to pick when multiple candidates exist'
      setup_autodiscover_dir
      write_config sqlode.yaml
      write_config sqlc.yaml
      When call generate_from_autodiscover_dir
      The status should be failure
      The output should include 'Multiple config files found'
      The output should include 'sqlode.yaml'
      The output should include 'sqlc.yaml'
      cleanup_autodiscover_dir
    End
  End
End
