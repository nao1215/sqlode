import gleam/list
import gleeunit
import gleeunit/should
import simplifile
import sqlode/model
import sqlode/query_parser

pub fn main() {
  gleeunit.main()
}

pub fn parse_queries_from_sqlc_annotations_test() {
  let assert Ok(content) = simplifile.read("test/fixtures/query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/query.sql",
      model.PostgreSQL,
      content,
    )

  list.length(queries) |> should.equal(2)

  let assert [get_author, list_authors] = queries
  get_author.name |> should.equal("GetAuthor")
  get_author.function_name |> should.equal("get_author")
  get_author.command |> should.equal(model.One)
  get_author.param_count |> should.equal(1)
  list_authors.function_name |> should.equal("list_authors")
  list_authors.command |> should.equal(model.Many)
}

pub fn reject_query_without_sql_body_test() {
  let content = "-- name: GetAuthor :one\n"

  let assert Error(error) =
    query_parser.parse_file("broken.sql", model.PostgreSQL, content)

  query_parser.error_to_string(error)
  |> should.equal("broken.sql:1: query GetAuthor is missing SQL body")
}
