import gleam/list
import gleam/string
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
  get_author.macros |> should.equal([])
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

pub fn count_mysql_placeholders_test() {
  let content =
    "-- name: CreateAuthor :exec\n"
    <> "INSERT INTO authors (name, bio) VALUES (?, ?);"

  let assert Ok(queries) =
    query_parser.parse_file("mysql.sql", model.MySQL, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
}

pub fn count_sqlite_named_placeholders_test() {
  let content =
    "-- name: GetAuthor :one\n"
    <> "SELECT id FROM authors WHERE id = :id OR name = @name OR slug = $slug OR code = ?1;"

  let assert Ok(queries) =
    query_parser.parse_file("sqlite.sql", model.SQLite, content)
  let assert [query] = queries

  query.param_count |> should.equal(4)
}

pub fn expand_sqlc_arg_macro_test() {
  let content =
    "-- name: GetByName :one\n"
    <> "SELECT id FROM authors WHERE name = sqlc.arg(author_name);"

  let assert Ok(queries) =
    query_parser.parse_file("arg.sql", model.PostgreSQL, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  query.macros
  |> should.equal([model.SqlcArg(index: 1, name: "author_name")])
  string.contains(query.sql, "sqlc.arg") |> should.be_false()
  string.contains(query.sql, "$1") |> should.be_true()
}

pub fn expand_sqlc_narg_macro_test() {
  let content =
    "-- name: UpdateBio :exec\n"
    <> "UPDATE authors SET bio = sqlc.narg(new_bio) WHERE id = sqlc.arg(author_id);"

  let assert Ok(queries) =
    query_parser.parse_file("narg.sql", model.PostgreSQL, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
  query.macros
  |> should.equal([
    model.SqlcNarg(index: 1, name: "new_bio"),
    model.SqlcArg(index: 2, name: "author_id"),
  ])
  string.contains(query.sql, "sqlc.narg") |> should.be_false()
  string.contains(query.sql, "sqlc.arg") |> should.be_false()
}

pub fn expand_sqlc_arg_mysql_test() {
  let content =
    "-- name: GetByName :one\n"
    <> "SELECT id FROM authors WHERE name = sqlc.arg(author_name);"

  let assert Ok(queries) =
    query_parser.parse_file("arg_mysql.sql", model.MySQL, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  string.contains(query.sql, "?") |> should.be_true()
}
