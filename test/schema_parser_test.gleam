import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlode/model
import sqlode/schema_parser

pub fn main() {
  gleeunit.main()
}

pub fn parse_create_table_columns_test() {
  let assert Ok(content) = simplifile.read("test/fixtures/schema.sql")
  let assert Ok(catalog) =
    schema_parser.parse_files([#("test/fixtures/schema.sql", content)])

  list.length(catalog.tables) |> should.equal(1)
  let assert [table] = catalog.tables
  table.name |> should.equal("authors")
  list.length(table.columns) |> should.equal(3)

  let assert [id, name, bio] = table.columns
  id.name |> should.equal("id")
  id.scalar_type |> should.equal(model.IntType)
  id.nullable |> should.equal(False)
  name.scalar_type |> should.equal(model.StringType)
  name.nullable |> should.equal(False)
  bio.nullable |> should.equal(True)
}

pub fn parse_extended_types_test() {
  let assert Ok(content) = simplifile.read("test/fixtures/extended_schema.sql")
  let assert Ok(catalog) =
    schema_parser.parse_files([
      #("test/fixtures/extended_schema.sql", content),
    ])

  let assert [table] = catalog.tables
  table.name |> should.equal("events")
  list.length(table.columns) |> should.equal(8)

  let assert [
    id,
    title,
    description,
    event_date,
    start_time,
    created_at,
    metadata,
    external_id,
  ] = table.columns

  id.scalar_type |> should.equal(model.IntType)
  title.scalar_type |> should.equal(model.StringType)
  description.nullable |> should.equal(True)
  event_date.scalar_type |> should.equal(model.DateType)
  start_time.scalar_type |> should.equal(model.TimeType)
  created_at.scalar_type |> should.equal(model.DateTimeType)
  metadata.scalar_type |> should.equal(model.JsonType)
  metadata.nullable |> should.equal(True)
  external_id.scalar_type |> should.equal(model.UuidType)
  external_id.nullable |> should.equal(False)
}

// Error and boundary tests

pub fn empty_schema_content_test() {
  let assert Ok(catalog) = schema_parser.parse_files([#("empty.sql", "")])
  catalog.tables |> should.equal([])
}

pub fn schema_with_only_whitespace_test() {
  let assert Ok(catalog) =
    schema_parser.parse_files([#("blank.sql", "   \n  \n  ")])
  catalog.tables |> should.equal([])
}

pub fn schema_with_comments_only_test() {
  let content = "-- This is a comment\n-- Another comment\n"
  let assert Ok(catalog) =
    schema_parser.parse_files([#("comments.sql", content)])
  catalog.tables |> should.equal([])
}

pub fn schema_missing_parenthesis_test() {
  let content = "CREATE TABLE broken name TEXT NOT NULL;"
  let assert Error(error) =
    schema_parser.parse_files([#("broken.sql", content)])
  let msg = schema_parser.error_to_string(error)
  string.contains(msg, "parenthesis") |> should.be_true()
}

pub fn schema_if_not_exists_test() {
  let content =
    "CREATE TABLE IF NOT EXISTS users (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  name TEXT NOT NULL\n"
    <> ");"
  let assert Ok(catalog) = schema_parser.parse_files([#("ifne.sql", content)])
  let assert [table] = catalog.tables
  table.name |> should.equal("users")
  list.length(table.columns) |> should.equal(2)
}

pub fn schema_quoted_table_name_test() {
  let content =
    "CREATE TABLE \"MyTable\" (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  name TEXT NOT NULL\n"
    <> ");"
  let assert Ok(catalog) = schema_parser.parse_files([#("quoted.sql", content)])
  let assert [table] = catalog.tables
  table.name |> should.equal("mytable")
}

pub fn schema_multiple_files_test() {
  let file1 = "CREATE TABLE a (id BIGSERIAL PRIMARY KEY);"
  let file2 = "CREATE TABLE b (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL);"
  let assert Ok(catalog) =
    schema_parser.parse_files([#("a.sql", file1), #("b.sql", file2)])
  list.length(catalog.tables) |> should.equal(2)
}

pub fn schema_table_with_constraints_test() {
  let content =
    "CREATE TABLE orders (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  user_id BIGINT NOT NULL,\n"
    <> "  total NUMERIC(10,2) NOT NULL,\n"
    <> "  FOREIGN KEY (user_id) REFERENCES users(id)\n"
    <> ");"
  let assert Ok(catalog) = schema_parser.parse_files([#("fk.sql", content)])
  let assert [table] = catalog.tables
  table.name |> should.equal("orders")
  // FOREIGN KEY constraint should not be parsed as a column
  list.length(table.columns) |> should.equal(3)
}

pub fn schema_enum_type_test() {
  let content =
    "CREATE TYPE mood AS ENUM ('happy', 'sad', 'neutral');\n"
    <> "CREATE TABLE people (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  current_mood mood NOT NULL\n"
    <> ");"
  let assert Ok(catalog) = schema_parser.parse_files([#("enum.sql", content)])
  let assert [enum] = catalog.enums
  enum.name |> should.equal("mood")
  enum.values |> should.equal(["happy", "sad", "neutral"])

  let assert [table] = catalog.tables
  let assert Ok(mood_col) =
    list.find(table.columns, fn(c) { c.name == "current_mood" })
  mood_col.scalar_type |> should.equal(model.EnumType("mood"))
}

pub fn error_to_string_invalid_column_test() {
  schema_parser.error_to_string(schema_parser.InvalidColumn(
    table: "users",
    detail: "missing type",
  ))
  |> string.contains("users")
  |> should.be_true()
}
