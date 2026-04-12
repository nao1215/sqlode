import gleam/list
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
