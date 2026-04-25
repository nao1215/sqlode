#!/bin/sh
# shellcheck shell=sh

Describe 'sqlode CLI'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  Describe 'init command'
    setup_init_test() {
      clean_test_output
      mkdir -p "$TEST_OUTPUT_DIR"
    }
    Before 'setup_init_test'
    After 'clean_test_output'

    It 'creates config file and stub files'
      When run init_cmd --output="$TEST_OUTPUT_DIR/sqlode.yaml"
      The status should be success
      The output should include 'Created'
      The path "$TEST_OUTPUT_DIR/sqlode.yaml" should be file
      The path "$TEST_OUTPUT_DIR/db/schema.sql" should be file
      The path "$TEST_OUTPUT_DIR/db/query.sql" should be file
    End

    It 'fails when config file already exists'
      mkdir -p "$TEST_OUTPUT_DIR"
      echo "existing" > "$TEST_OUTPUT_DIR/sqlode.yaml"
      When run init_cmd --output="$TEST_OUTPUT_DIR/sqlode.yaml"
      The status should be failure
      The output should include 'already exists'
    End

    It 'scaffolds mysql + native runtime'
      When run init_cmd --output="$TEST_OUTPUT_DIR/sqlode.yaml" --engine=mysql --runtime=native
      The status should be success
      The output should include 'Created'
      The path "$TEST_OUTPUT_DIR/sqlode.yaml" should be file
      The contents of file "$TEST_OUTPUT_DIR/sqlode.yaml" should include 'engine: "mysql"'
      The contents of file "$TEST_OUTPUT_DIR/sqlode.yaml" should include 'runtime: "native"'
      The contents of file "$TEST_OUTPUT_DIR/db/schema.sql" should include 'BIGINT AUTO_INCREMENT PRIMARY KEY'
    End
  End

  Describe 'generate command'
    It 'fails when config file does not exist'
      When run generate --config=nonexistent.yaml
      The status should be failure
      The output should include 'Config file not found'
    End

    It 'fails with invalid config'
      When run generate --config=test/fixtures/malformed.yaml
      The status should be failure
      The output should include 'Error'
    End
  End

  Describe 'verify command'
    It 'fails when config file does not exist'
      When run verify_cmd --config=nonexistent.yaml
      The status should be failure
      The output should include 'Config file not found'
    End

    It 'fails with invalid config'
      When run verify_cmd --config=test/fixtures/malformed.yaml
      The status should be failure
      The output should include 'Error'
    End
  End

  Describe 'version command'
    It 'outputs the version string'
      When run version_cmd
      The status should be success
      The output should include 'sqlode v'
    End
  End

  Describe 'help flags'
    It 'init --help shows usage'
      When run init_cmd --help
      The status should be success
      The output should include 'Scaffold a sqlode.yaml'
    End

    It 'version --help shows usage'
      When run version_cmd --help
      The status should be success
      The output should include 'Print the sqlode version'
    End
  End

  Describe 'error diagnostics routing (#465)'
    # Pin POSIX/CLIG behaviour: error messages from invalid invocations
    # land on stderr (not stdout), so wrappers using `1>out 2>err`
    # can distinguish requested output from diagnostics.

    It 'sends unknown-flag errors to stderr, not stdout'
      When run sqlode_raw --xyz
      The status should be failure
      # Error diagnostic must reach stderr.
      The error should include 'error'
      # And must NOT appear on stdout.
      The output should not include 'error: failed to run command'
    End

    It 'sends no-args errors to stderr, not stdout'
      When run sqlode_raw
      The status should be failure
      The error should include 'error'
      The output should not include 'error: failed to run command'
    End

    It 'still prints --help text on stdout (requested output)'
      When run sqlode_raw --help
      The status should be success
      # The help text is the requested output and stays on stdout.
      The output should include 'sqlode'
    End
  End
End
