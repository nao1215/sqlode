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
End
