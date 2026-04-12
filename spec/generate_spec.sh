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

    It 'writes queries.gleam from sqlc style input'
      When run generate --config=test/fixtures/sqlode.yaml
      The status should be success
      The output should include 'Successfully generated 2 files'
      The path "$TEST_OUTPUT_DIR/db/params.gleam" should be file
      The path "$TEST_OUTPUT_DIR/db/queries.gleam" should be file
      The contents of file "$TEST_OUTPUT_DIR/db/params.gleam" should include 'GetAuthorParams(id: Int)'
      The contents of file "$TEST_OUTPUT_DIR/db/params.gleam" should include 'runtime.int(params.id)'
      The contents of file "$TEST_OUTPUT_DIR/db/queries.gleam" should include 'pub fn get_author() -> Query {'
      The contents of file "$TEST_OUTPUT_DIR/db/queries.gleam" should include 'pub fn list_authors() -> Query {'
    End
  End
End
