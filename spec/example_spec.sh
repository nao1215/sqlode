#!/bin/sh
# shellcheck shell=sh

Describe 'examples/sqlite-basic'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  EXAMPLE_DIR="$PROJECT_ROOT/examples/sqlite-basic"
  GENERATED_DIR="$EXAMPLE_DIR/src/db"

  clean_generated() {
    rm -rf "$GENERATED_DIR"
  }

  Describe 'tutorial freshness'
    Before 'clean_generated'
    After 'clean_generated'

    It 'regenerates params, models, queries, and the sqlight adapter'
      When run generate --config="$EXAMPLE_DIR/sqlode.yaml"
      The status should be success
      The output should include 'Successfully generated'
      The path "$GENERATED_DIR/params.gleam" should be file
      The path "$GENERATED_DIR/models.gleam" should be file
      The path "$GENERATED_DIR/queries.gleam" should be file
      The path "$GENERATED_DIR/sqlight_adapter.gleam" should be file
      The contents of file "$GENERATED_DIR/params.gleam" should include 'GetAuthorParams(id: Int)'
      The contents of file "$GENERATED_DIR/params.gleam" should include 'CreateAuthorParams(name: String'
      The contents of file "$GENERATED_DIR/sqlight_adapter.gleam" should include 'pub fn get_author('
      The contents of file "$GENERATED_DIR/sqlight_adapter.gleam" should include 'pub fn list_authors('
      The contents of file "$GENERATED_DIR/sqlight_adapter.gleam" should include 'pub fn create_author('
      The contents of file "$GENERATED_DIR/sqlight_adapter.gleam" should include 'pub fn delete_author('
    End
  End
End
