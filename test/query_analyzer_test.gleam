import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlode/lexer
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer
import sqlode/query_analyzer/context
import sqlode/query_analyzer/expr_parser
import sqlode/query_analyzer/token_utils
import sqlode/query_ir
import sqlode/query_parser
import sqlode/schema_parser

pub fn main() {
  gleeunit.main()
}

pub fn infer_param_type_from_where_clause_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [get_author, list_authors] = analyzed

  get_author.params
  |> should.equal([
    model.QueryParam(
      index: 1,
      field_name: "id",
      scalar_type: model.IntType,
      nullable: False,
      is_list: False,
    ),
  ])
  list_authors.params |> should.equal([])
}

pub fn infer_insert_param_types_from_column_order_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/create_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/create_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [create_author] = analyzed

  create_author.params
  |> should.equal([
    model.QueryParam(
      index: 1,
      field_name: "name",
      scalar_type: model.StringType,
      nullable: False,
      is_list: False,
    ),
    model.QueryParam(
      index: 2,
      field_name: "bio",
      scalar_type: model.StringType,
      nullable: True,
      is_list: False,
    ),
  ])
}

pub fn infer_result_columns_for_select_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [get_author, list_authors] = analyzed

  get_author.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    )),
  ])

  list_authors.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    )),
  ])
}

pub fn infer_no_result_columns_for_exec_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/create_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/create_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [create_author] = analyzed

  create_author.result_columns |> should.equal([])
}

pub fn infer_result_columns_with_star_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql = "-- name: GetAllAuthors :many\nSELECT * FROM authors;"
  let assert Ok(queries) =
    query_parser.parse_file("star.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [get_all] = analyzed

  get_all.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "bio",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("authors"),
    )),
  ])
}

pub fn infer_result_columns_with_table_prefix_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetAuthorPrefixed :one\nSELECT authors.id, authors.name FROM authors WHERE authors.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("prefix.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [get_author] = analyzed

  get_author.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    )),
  ])
}

pub fn sqlc_arg_sets_param_name_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetByName :one\nSELECT id, name FROM authors WHERE name = sqlode.arg(author_name);"
  let assert Ok(queries) =
    query_parser.parse_file("arg.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  query.params
  |> should.equal([
    model.QueryParam(
      index: 1,
      field_name: "author_name",
      scalar_type: model.StringType,
      nullable: False,
      is_list: False,
    ),
  ])
}

pub fn sqlc_narg_sets_nullable_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: UpdateBio :exec\nUPDATE authors SET bio = sqlode.narg(new_bio) WHERE id = sqlode.arg(author_id);"
  let assert Ok(queries) =
    query_parser.parse_file("narg.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [bio_param, id_param] = query.params
  bio_param.field_name |> should.equal("new_bio")
  bio_param.nullable |> should.equal(True)
  id_param.field_name |> should.equal("author_id")
  id_param.nullable |> should.equal(False)
}

pub fn sqlc_slice_sets_is_list_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetByIds :many\nSELECT id, name FROM authors WHERE id IN (sqlode.slice(ids));"
  let assert Ok(queries) =
    query_parser.parse_file("slice.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [param] = query.params
  param.field_name |> should.equal("ids")
  param.is_list |> should.equal(True)
}

pub fn parse_enum_column_type_test() {
  let schema =
    "CREATE TYPE status AS ENUM ('active', 'inactive', 'banned');
CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  status status NOT NULL
);"

  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("enum.sql", schema)])

  let assert [table] = catalog.tables
  let assert [_id, _name, status_col] = table.columns
  status_col.scalar_type |> should.equal(model.EnumType("status"))

  let assert [enum_def] = catalog.enums
  enum_def.name |> should.equal("status")
  enum_def.values |> should.equal(["active", "inactive", "banned"])
}

pub fn join_result_columns_test() {
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookWithAuthor :one\nSELECT books.title, authors.name FROM books JOIN authors ON books.author_id = authors.id WHERE books.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("join.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  query.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "title",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("books"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    )),
  ])
}

pub fn sqlc_embed_expands_table_columns_test() {
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookFull :one\nSELECT sqlode.embed(authors), books.title FROM books JOIN authors ON books.author_id = authors.id WHERE books.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("embed.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.EmbeddedResult(embed_col), model.ScalarResult(title_col)] =
    query.result_columns
  embed_col.name |> should.equal("authors")
  embed_col.table_name |> should.equal("authors")
  list.length(embed_col.columns) |> should.equal(3)
  title_col.name |> should.equal("title")
}

pub fn sqlc_embed_rewrites_sql_to_column_list_test() {
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookFull :one\nSELECT sqlode.embed(authors), books.title FROM books JOIN authors ON books.author_id = authors.id WHERE books.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("embed.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  // The literal sqlode.embed(...) macro must not leak into emitted SQL.
  string.contains(query.base.sql, "sqlode.embed(") |> should.be_false()
  // Every column of the embedded table must appear as a qualified reference.
  string.contains(query.base.sql, "authors.id") |> should.be_true()
  string.contains(query.base.sql, "authors.name") |> should.be_true()
  string.contains(query.base.sql, "authors.bio") |> should.be_true()
  // Non-embed parts of the query are preserved.
  string.contains(query.base.sql, "books.title") |> should.be_true()
}

pub fn sqlc_embed_rewrite_ignores_case_and_whitespace_test() {
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookFull :one\nSELECT Sqlode.Embed( authors ), books.title FROM books JOIN authors ON books.author_id = authors.id WHERE books.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("embed.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  string.contains(query.base.sql, "embed(") |> should.be_false()
  string.contains(query.base.sql, "authors.id") |> should.be_true()
}

pub fn sqlc_embed_rewrite_preserves_queries_without_embed_test() {
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookTitle :one\nSELECT books.title FROM books WHERE books.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("plain.sql", model.PostgreSQL, naming_ctx, sql)
  let assert [parsed] = queries
  let original_sql = parsed.base.sql

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  query.base.sql |> should.equal(original_sql)
}

pub fn returning_clause_result_columns_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: CreateAuthorReturning :one\nINSERT INTO authors (name, bio) VALUES ($1, $2) RETURNING id, name;"
  let assert Ok(queries) =
    query_parser.parse_file("ret.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  query.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    )),
  ])
}

pub fn returning_clause_with_function_expression_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: CreateAuthorCoalesce :one\nINSERT INTO authors (name, bio) VALUES ($1, $2) RETURNING id, COALESCE(bio, name) AS display;"
  let assert Ok(queries) =
    query_parser.parse_file("ret_fn.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [id_col, display_col] = query.result_columns
  id_col
  |> should.equal(
    model.ScalarResult(model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    )),
  )
  // COALESCE(bio, name) should resolve to StringType
  display_col
  |> should.equal(
    model.ScalarResult(model.ResultColumn(
      name: "display",
      scalar_type: model.StringType,
      nullable: False,
      source_table: None,
    )),
  )
}

pub fn cte_select_from_real_table_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetRecentAuthors :many\nWITH filtered AS (SELECT id FROM authors WHERE id > 0) SELECT authors.id, authors.name FROM authors JOIN filtered ON authors.id = filtered.id;"
  let assert Ok(queries) =
    query_parser.parse_file("cte.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.name |> should.equal("id")
  id_col.scalar_type |> should.equal(model.IntType)
  name_col.name |> should.equal("name")
}

pub fn compound_query_column_count_mismatch_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let content =
    "-- name: BadUnion :many
SELECT id, name FROM authors
UNION
SELECT id FROM authors;"

  let assert Ok(queries) =
    query_parser.parse_file("union.sql", model.PostgreSQL, naming_ctx, content)
  let assert Error(err) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let msg = query_analyzer.analysis_error_to_string(err, model.PostgreSQL)
  msg |> string.contains("2") |> should.be_true()
  msg |> string.contains("1") |> should.be_true()
  msg |> string.contains("BadUnion") |> should.be_true()
}

pub fn compound_query_valid_union_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let content =
    "-- name: GoodUnion :many
SELECT id, name FROM authors
UNION ALL
SELECT id, name FROM authors;"

  let assert Ok(queries) =
    query_parser.parse_file("union.sql", model.PostgreSQL, naming_ctx, content)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  list.length(query.result_columns) |> should.equal(2)
}

pub fn compound_query_except_mismatch_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let content =
    "-- name: BadExcept :many
SELECT id, name FROM authors
EXCEPT
SELECT id, name, bio FROM authors;"

  let assert Ok(queries) =
    query_parser.parse_file("except.sql", model.PostgreSQL, naming_ctx, content)
  let assert Error(_) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
}

fn test_catalog() -> model.Catalog {
  let assert Ok(content) = simplifile.read("test/fixtures/schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("test/fixtures/schema.sql", content)])

  catalog
}

pub fn type_cast_infers_param_type_test() {
  let naming_ctx = naming.new()
  let catalog = typecast_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/typecast_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/typecast_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  // GetUserByUuid: $1::int should infer IntType
  let assert [get_user, create_user] = analyzed
  let assert [param] = get_user.params
  param.scalar_type |> should.equal(model.IntType)

  // CreateUserWithUuid: $2::jsonb should infer JsonType
  let assert [_, param2] = create_user.params
  param2.scalar_type |> should.equal(model.JsonType)
}

fn typecast_catalog() -> model.Catalog {
  let assert Ok(content) = simplifile.read("test/fixtures/typecast_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("test/fixtures/typecast_schema.sql", content)])

  catalog
}

// Error path tests

pub fn table_not_found_error_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetMissing :many\nSELECT * FROM nonexistent WHERE id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("missing.sql", model.PostgreSQL, naming_ctx, sql)

  let result =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  result |> should.be_error()
}

pub fn analysis_error_to_string_table_not_found_test() {
  let error = context.TableNotFound(query_name: "GetUsers", table_name: "users")
  let msg = query_analyzer.analysis_error_to_string(error, model.PostgreSQL)
  string.contains(msg, "GetUsers") |> should.be_true()
  string.contains(msg, "users") |> should.be_true()
  string.contains(msg, "not found") |> should.be_true()
}

pub fn analysis_error_to_string_column_not_found_test() {
  let error =
    context.ColumnNotFound(
      query_name: "GetUser",
      table_name: "users",
      column_name: "email",
    )
  let msg = query_analyzer.analysis_error_to_string(error, model.PostgreSQL)
  string.contains(msg, "GetUser") |> should.be_true()
  string.contains(msg, "email") |> should.be_true()
  string.contains(msg, "users") |> should.be_true()
}

pub fn parameter_type_not_inferred_error_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql = "-- name: Bare :many\nSELECT $1;"
  let assert Ok(queries) =
    query_parser.parse_file("bare.sql", model.PostgreSQL, naming_ctx, sql)

  let result =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  result |> should.be_error()
}

pub fn unrecognized_cast_type_error_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: BadCast :many\nSELECT id, name FROM authors WHERE id = $1::geometry;"
  let assert Ok(queries) =
    query_parser.parse_file("badcast.sql", model.PostgreSQL, naming_ctx, sql)

  let result =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  result |> should.be_error()
}

pub fn analysis_error_to_string_parameter_not_inferred_test() {
  let error =
    context.ParameterTypeNotInferred(query_name: "Bare", param_index: 1)
  let msg = query_analyzer.analysis_error_to_string(error, model.PostgreSQL)
  string.contains(msg, "Bare") |> should.be_true()
  string.contains(msg, "$1") |> should.be_true()
}

pub fn analysis_error_to_string_unrecognized_cast_test() {
  let error =
    context.UnrecognizedCastType(
      query_name: "BadCast",
      param_index: 1,
      cast_type: "geometry",
    )
  let msg = query_analyzer.analysis_error_to_string(error, model.PostgreSQL)
  string.contains(msg, "BadCast") |> should.be_true()
  string.contains(msg, "geometry") |> should.be_true()
}

// --- Engine-aware cast hint (#473) ---
//
// Pin the per-engine wording so the suggested fix in the error
// message matches the configured engine's dialect — `$N::int` for
// PostgreSQL, `CAST(? AS INTEGER)` for SQLite, `CAST(? AS SIGNED)`
// for MySQL — and the placeholder reference matches too. Following
// the suggestion as-is must produce valid SQL for the engine.

pub fn parameter_not_inferred_postgres_uses_dollar_cast_hint_test() {
  let error =
    context.ParameterTypeNotInferred(query_name: "Bare", param_index: 1)
  let msg = query_analyzer.analysis_error_to_string(error, model.PostgreSQL)
  string.contains(msg, "$1") |> should.be_true()
  string.contains(msg, "$1::int") |> should.be_true()
}

pub fn parameter_not_inferred_sqlite_uses_cast_as_integer_hint_test() {
  // Headline #473 case: SQLite must NOT see `$1::int` (Postgres
  // syntax). The placeholder reference uses `?N` and the suggested
  // cast uses ANSI-shaped `CAST(? AS INTEGER)`.
  let error =
    context.ParameterTypeNotInferred(query_name: "Bare", param_index: 1)
  let msg = query_analyzer.analysis_error_to_string(error, model.SQLite)
  string.contains(msg, "?1") |> should.be_true()
  string.contains(msg, "CAST(? AS INTEGER)") |> should.be_true()
  string.contains(msg, "$1") |> should.be_false()
  string.contains(msg, "::int") |> should.be_false()
}

pub fn parameter_not_inferred_mysql_uses_cast_as_signed_hint_test() {
  let error =
    context.ParameterTypeNotInferred(query_name: "Bare", param_index: 2)
  let msg = query_analyzer.analysis_error_to_string(error, model.MySQL)
  string.contains(msg, "?2") |> should.be_true()
  string.contains(msg, "CAST(? AS SIGNED)") |> should.be_true()
  string.contains(msg, "$2") |> should.be_false()
  string.contains(msg, "::int") |> should.be_false()
}

pub fn unrecognized_cast_sqlite_uses_question_mark_label_test() {
  // Placeholder reference dialect must follow the engine for every
  // error variant, not just ParameterTypeNotInferred.
  let error =
    context.UnrecognizedCastType(
      query_name: "BadCast",
      param_index: 3,
      cast_type: "geometry",
    )
  let msg = query_analyzer.analysis_error_to_string(error, model.SQLite)
  string.contains(msg, "?3") |> should.be_true()
  string.contains(msg, "$3") |> should.be_false()
}

pub fn parameter_type_conflict_mysql_uses_question_mark_label_test() {
  let error =
    context.ParameterTypeConflict(
      query_name: "Conflict",
      param_index: 5,
      type_a: model.IntType,
      type_b: model.StringType,
    )
  let msg = query_analyzer.analysis_error_to_string(error, model.MySQL)
  string.contains(msg, "?5") |> should.be_true()
  string.contains(msg, "$5") |> should.be_false()
}

pub fn left_join_makes_right_table_nullable_test() {
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookWithAuthor :one\nSELECT books.title, authors.name FROM books LEFT JOIN authors ON books.author_id = authors.id WHERE books.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("lj.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  query.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "title",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("books"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("authors"),
    )),
  ])
}

pub fn aliased_qualified_column_with_left_join_test() {
  // Regression: `authors.name AS author_name` with LEFT JOIN previously
  // failed because the catalog was looked up by the alias "author_name"
  // instead of the real column "name", then fell through to expression-
  // based inference which lost the LEFT JOIN nullability.
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookWithAuthor :one\nSELECT books.title, authors.name AS author_name FROM books LEFT JOIN authors ON books.author_id = authors.id WHERE books.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("alj.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  query.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "title",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("books"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "author_name",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("authors"),
    )),
  ])
}

pub fn right_join_makes_left_table_nullable_test() {
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookWithAuthor :one\nSELECT books.title, authors.name FROM books RIGHT JOIN authors ON books.author_id = authors.id;"
  let assert Ok(queries) =
    query_parser.parse_file("rj.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  query.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "title",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("books"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    )),
  ])
}

pub fn full_join_makes_both_tables_nullable_test() {
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: GetBookWithAuthor :one\nSELECT books.title, authors.name FROM books FULL JOIN authors ON books.author_id = authors.id;"
  let assert Ok(queries) =
    query_parser.parse_file("fj.sql", model.PostgreSQL, naming_ctx, sql)

  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  query.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "title",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("books"),
    )),
    model.ScalarResult(model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("authors"),
    )),
  ])
}

pub fn sqlite_repeated_named_placeholder_single_param_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: ReusedNamed :one
SELECT id FROM authors WHERE name = :name OR bio = :name;"

  let assert Ok(queries) =
    query_parser.parse_file("dedup.sql", model.SQLite, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)
  let assert [query] = analyzed

  // Repeated :name should produce exactly one parameter
  list.length(query.params) |> should.equal(1)
  let assert [param] = query.params
  param.index |> should.equal(1)
  param.scalar_type |> should.equal(model.StringType)
}

pub fn sqlite_repeated_and_distinct_placeholders_correct_index_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: MixedDedup :one
SELECT id FROM authors WHERE name = :name AND bio = :name AND id = :id;"

  let assert Ok(queries) =
    query_parser.parse_file("mixed.sql", model.SQLite, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)
  let assert [query] = analyzed

  // :name deduped to index=1, :id gets index=2
  list.length(query.params) |> should.equal(2)
  let assert [name_param, id_param] = query.params
  name_param.index |> should.equal(1)
  name_param.scalar_type |> should.equal(model.StringType)
  id_param.index |> should.equal(2)
  id_param.scalar_type |> should.equal(model.IntType)
}

pub fn sqlite_repeated_at_placeholder_single_param_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  // Same placeholder used with columns of different types (id:Int, name:String)
  // should produce a type conflict error
  let sql =
    "-- name: ReusedAt :one
SELECT id FROM authors WHERE id = @id OR name = @id;"

  let assert Ok(queries) =
    query_parser.parse_file("at.sql", model.SQLite, naming_ctx, sql)
  let result =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)
  let assert Error(context.ParameterTypeConflict(
    query_name: "ReusedAt",
    param_index: 1,
    type_a: model.IntType,
    type_b: model.StringType,
  )) = result
}

pub fn sqlite_repeated_at_placeholder_same_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  // Same placeholder used with columns of the same type should succeed
  let sql =
    "-- name: ReusedSameType :one
SELECT id FROM authors WHERE id = @id OR id > @id;"

  let assert Ok(queries) =
    query_parser.parse_file("at.sql", model.SQLite, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)
  let assert [query] = analyzed

  list.length(query.params) |> should.equal(1)
  let assert [param] = query.params
  param.index |> should.equal(1)
  param.scalar_type |> should.equal(model.IntType)
}

fn join_catalog() -> model.Catalog {
  let assert Ok(content) = simplifile.read("test/fixtures/join_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#("test/fixtures/join_schema.sql", content)])

  catalog
}

// --- Expression-based column tests ---

pub fn count_expression_infers_int_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/expression_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/expression_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  // CountAuthors: COUNT(*) AS total → Int, not nullable
  let assert [count_query, ..] = analyzed
  let assert [
    model.ScalarResult(model.ResultColumn(
      name: "total",
      scalar_type: model.IntType,
      ..,
    )),
  ] = count_query.result_columns
}

pub fn sum_avg_expression_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/expression_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/expression_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  // SumAndAvg: SUM(id) AS id_sum → Int(nullable), AVG(id) AS id_avg → Float(nullable)
  let assert [_, sum_avg_query, ..] = analyzed
  let assert [
    model.ScalarResult(model.ResultColumn(
      name: "id_sum",
      scalar_type: model.IntType,
      nullable: True,
      ..,
    )),
    model.ScalarResult(model.ResultColumn(
      name: "id_avg",
      scalar_type: model.FloatType,
      nullable: True,
      ..,
    )),
  ] = sum_avg_query.result_columns
}

pub fn coalesce_expression_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/expression_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/expression_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  // CoalesceNullable: COALESCE(bio, 'N/A') AS bio_text → String, not nullable
  let assert [_, _, coalesce_query, ..] = analyzed
  let assert [_, model.ScalarResult(bio_col)] = coalesce_query.result_columns
  let assert model.ResultColumn(
    name: "bio_text",
    scalar_type: model.StringType,
    nullable: False,
    ..,
  ) = bio_col
}

pub fn cast_expression_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/expression_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/expression_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  // CastColumn: CAST(name AS TEXT) AS name_text → String
  let assert [_, _, _, cast_query, ..] = analyzed
  let assert [_, model.ScalarResult(name_col)] = cast_query.result_columns
  let assert model.ResultColumn(
    name: "name_text",
    scalar_type: model.StringType,
    ..,
  ) = name_col
}

pub fn literal_expression_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let assert Ok(content) = simplifile.read("test/fixtures/expression_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/expression_query.sql",
      model.PostgreSQL,
      naming_ctx,
      content,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  // LiteralSelect: 1 AS one → Int, 'hello' AS greeting → String
  let assert [_, _, _, _, literal_query] = analyzed
  let assert [model.ScalarResult(one_col), model.ScalarResult(greeting_col)] =
    literal_query.result_columns
  let assert model.ResultColumn(
    name: "one",
    scalar_type: model.IntType,
    nullable: False,
    ..,
  ) = one_col
  let assert model.ResultColumn(
    name: "greeting",
    scalar_type: model.StringType,
    nullable: False,
    ..,
  ) = greeting_col
}

// --- New expression type inference tests ---

pub fn exists_subquery_infers_bool_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: HasAuthor :one\nSELECT EXISTS(SELECT 1 FROM authors WHERE id = $1) AS present FROM authors LIMIT 1;"
  let assert Ok(queries) =
    query_parser.parse_file("exists.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.ScalarResult(col)] = query.result_columns
  let assert model.ResultColumn(
    name: "present",
    scalar_type: model.BoolType,
    nullable: False,
    ..,
  ) = col
}

pub fn boolean_comparison_infers_bool_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: IsAdult :one\nSELECT authors.id > 0 AS is_positive FROM authors WHERE id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("cmp.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.ScalarResult(col)] = query.result_columns
  let assert model.ResultColumn(
    name: "is_positive",
    scalar_type: model.BoolType,
    nullable: False,
    ..,
  ) = col
}

pub fn string_concat_infers_string_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: FullName :one\nSELECT name || ' - ' || bio AS display FROM authors WHERE id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("concat.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.ScalarResult(col)] = query.result_columns
  let assert model.ResultColumn(
    name: "display",
    scalar_type: model.StringType,
    nullable: False,
    ..,
  ) = col
}

pub fn arithmetic_expression_infers_int_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: NextId :one\nSELECT id + 1 AS next_id FROM authors WHERE id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("arith.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.ScalarResult(col)] = query.result_columns
  let assert model.ResultColumn(
    name: "next_id",
    scalar_type: model.IntType,
    nullable: False,
    ..,
  ) = col
}

pub fn lower_function_infers_string_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: LowerName :one\nSELECT lower(name) AS lower_name FROM authors WHERE id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("lower.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.ScalarResult(col)] = query.result_columns
  let assert model.ResultColumn(
    name: "lower_name",
    scalar_type: model.StringType,
    nullable: False,
    ..,
  ) = col
}

pub fn length_function_infers_int_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: NameLen :one\nSELECT length(name) AS name_len FROM authors WHERE id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("length.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.ScalarResult(col)] = query.result_columns
  let assert model.ResultColumn(
    name: "name_len",
    scalar_type: model.IntType,
    nullable: False,
    ..,
  ) = col
}

pub fn abs_function_resolves_inner_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: AbsVal :one\nSELECT abs(id) AS abs_id FROM authors WHERE id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("abs.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.ScalarResult(col)] = query.result_columns
  let assert model.ResultColumn(
    name: "abs_id",
    scalar_type: model.IntType,
    nullable: False,
    ..,
  ) = col
}

pub fn unsupported_expression_error_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: Unknown :one\nSELECT my_custom_udf(id) AS result FROM authors WHERE id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("udf.sql", model.PostgreSQL, naming_ctx, sql)

  let result =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  result |> should.be_error()
}

pub fn not_exists_infers_bool_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: NotExists :one\nSELECT NOT EXISTS(SELECT 1 FROM authors WHERE id = 0) AS no_match FROM authors LIMIT 1;"
  let assert Ok(queries) =
    query_parser.parse_file("notexists.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.ScalarResult(col)] = query.result_columns
  let assert model.ResultColumn(
    name: "no_match",
    scalar_type: model.BoolType,
    nullable: False,
    ..,
  ) = col
}

pub fn greatest_infers_first_arg_type_nullable_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: MaxId :one\nSELECT GREATEST(id, 0) AS max_id FROM authors WHERE id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("greatest.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed

  let assert [model.ScalarResult(col)] = query.result_columns
  let assert model.ResultColumn(
    name: "max_id",
    scalar_type: model.IntType,
    nullable: True,
    ..,
  ) = col
}

pub fn unsupported_expression_error_message_test() {
  let error =
    context.UnsupportedExpression(
      query_name: "BadQuery",
      expression: "my_custom_udf(id)",
    )
  let msg = query_analyzer.analysis_error_to_string(error, model.PostgreSQL)
  string.contains(msg, "unsupported expression") |> should.be_true()
  string.contains(msg, "BadQuery") |> should.be_true()
}

// --- Window function type inference ---

pub fn row_number_window_function_infers_int_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: RankedAuthors :many\nSELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rank FROM authors;"
  let assert Ok(queries) =
    query_parser.parse_file("rn.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [_id, model.ScalarResult(rank_col)] = query.result_columns
  rank_col.name |> should.equal("rank")
  rank_col.scalar_type |> should.equal(model.IntType)
  rank_col.nullable |> should.equal(False)
}

pub fn percent_rank_window_function_infers_float_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: Percentiles :many\nSELECT id, PERCENT_RANK() OVER (ORDER BY id) AS pct FROM authors;"
  let assert Ok(queries) =
    query_parser.parse_file("pct.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [_id, model.ScalarResult(pct_col)] = query.result_columns
  pct_col.scalar_type |> should.equal(model.FloatType)
}

pub fn lag_window_function_infers_first_arg_type_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: PrevName :many\nSELECT id, LAG(name) OVER (ORDER BY id) AS prev_name FROM authors;"
  let assert Ok(queries) =
    query_parser.parse_file("lag.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [_id, model.ScalarResult(prev_col)] = query.result_columns
  prev_col.name |> should.equal("prev_name")
  prev_col.scalar_type |> should.equal(model.StringType)
  // lag can produce NULL when there is no preceding row
  prev_col.nullable |> should.equal(True)
}

pub fn ntile_window_function_infers_int_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: Quartile :many\nSELECT id, NTILE(4) OVER (ORDER BY id) AS q FROM authors;"
  let assert Ok(queries) =
    query_parser.parse_file("ntile.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [_id, model.ScalarResult(q_col)] = query.result_columns
  q_col.scalar_type |> should.equal(model.IntType)
}

// --- Batch 1: GROUP BY ROLLUP / CUBE / GROUPING SETS, FILTER, DISTINCT ON,
//     ANY/ALL subquery operators ---

fn analyze_one(sql: String, catalog: model.Catalog) -> model.AnalyzedQuery {
  let naming_ctx = naming.new()
  let assert Ok(queries) =
    query_parser.parse_file("b1.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  query
}

pub fn group_by_rollup_does_not_break_select_inference_test() {
  let sql =
    "-- name: AuthorsByName :many\nSELECT name, COUNT(*) AS total FROM authors GROUP BY ROLLUP(name);"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(name_col), model.ScalarResult(total_col)] =
    query.result_columns
  name_col.name |> should.equal("name")
  name_col.scalar_type |> should.equal(model.StringType)
  total_col.name |> should.equal("total")
  total_col.scalar_type |> should.equal(model.IntType)
}

pub fn group_by_cube_does_not_break_select_inference_test() {
  let sql =
    "-- name: AuthorsByCube :many\nSELECT name, COUNT(*) AS total FROM authors GROUP BY CUBE(name);"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(name_col), model.ScalarResult(total_col)] =
    query.result_columns
  name_col.scalar_type |> should.equal(model.StringType)
  total_col.scalar_type |> should.equal(model.IntType)
}

pub fn group_by_grouping_sets_does_not_break_select_inference_test() {
  let sql =
    "-- name: AuthorsByGS :many\nSELECT name, COUNT(*) AS total FROM authors GROUP BY GROUPING SETS ((name), ());"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(name_col), model.ScalarResult(total_col)] =
    query.result_columns
  name_col.scalar_type |> should.equal(model.StringType)
  total_col.scalar_type |> should.equal(model.IntType)
}

pub fn filter_clause_after_aggregate_test() {
  // SUM(...) FILTER (WHERE ...) — the FILTER clause must not break
  // result column extraction or aggregate type inference.
  let sql =
    "-- name: SumPositive :one\nSELECT SUM(id) FILTER (WHERE id > 0) AS positive FROM authors;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(col)] = query.result_columns
  col.name |> should.equal("positive")
  col.scalar_type |> should.equal(model.IntType)
}

pub fn distinct_on_skips_column_list_test() {
  // DISTINCT ON (col) prefix must not be picked up as a result column.
  let sql =
    "-- name: LatestPerName :many\nSELECT DISTINCT ON (name) id, name FROM authors ORDER BY name, id DESC;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.name |> should.equal("id")
  name_col.name |> should.equal("name")
}

pub fn any_subquery_in_where_test() {
  // `id = ANY (SELECT ...)` should not derail SELECT inference.
  let sql =
    "-- name: AuthorsAnyId :many\nSELECT id, name FROM authors WHERE id = ANY (SELECT id FROM authors);"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.name |> should.equal("id")
  name_col.name |> should.equal("name")
}

pub fn all_subquery_in_where_test() {
  let sql =
    "-- name: AuthorsAllId :many\nSELECT id, name FROM authors WHERE id > ALL (SELECT id FROM authors);"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.name |> should.equal("id")
  name_col.name |> should.equal("name")
}

// --- Batch 2: JSON / Array operator type inference ---

fn extended_catalog() -> model.Catalog {
  let assert Ok(content) = simplifile.read("test/fixtures/extended_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([
      #("test/fixtures/extended_schema.sql", content),
    ])
  catalog
}

pub fn json_arrow_extract_returns_json_test() {
  let sql =
    "-- name: GetMeta :one\nSELECT id, metadata->'foo' AS extracted FROM events WHERE id = $1;"
  let query = analyze_one(sql, extended_catalog())
  let assert [_id, model.ScalarResult(col)] = query.result_columns
  col.name |> should.equal("extracted")
  col.scalar_type |> should.equal(model.JsonType)
  col.nullable |> should.equal(True)
}

pub fn json_double_arrow_extract_returns_text_test() {
  let sql =
    "-- name: GetMetaText :one\nSELECT id, metadata->>'foo' AS extracted FROM events WHERE id = $1;"
  let query = analyze_one(sql, extended_catalog())
  let assert [_id, model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.StringType)
  col.nullable |> should.equal(True)
}

pub fn json_path_extract_returns_json_test() {
  let sql =
    "-- name: GetMetaPath :one\nSELECT id, metadata#>'{a,b}' AS extracted FROM events WHERE id = $1;"
  let query = analyze_one(sql, extended_catalog())
  let assert [_id, model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.JsonType)
}

pub fn json_path_extract_text_returns_text_test() {
  let sql =
    "-- name: GetMetaPathText :one\nSELECT id, metadata#>>'{a,b}' AS extracted FROM events WHERE id = $1;"
  let query = analyze_one(sql, extended_catalog())
  let assert [_id, model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.StringType)
}

pub fn json_containment_returns_bool_test() {
  let sql =
    "-- name: HasKey :one\nSELECT id, metadata @> '{}' AS contains FROM events WHERE id = $1;"
  let query = analyze_one(sql, extended_catalog())
  let assert [_id, model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.BoolType)
}

pub fn array_overlap_returns_bool_test() {
  let sql =
    "-- name: ArrayOverlap :one\nSELECT id, metadata && '{}' AS overlap FROM events WHERE id = $1;"
  let query = analyze_one(sql, extended_catalog())
  let assert [_id, model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.BoolType)
}

pub fn jsonb_key_existence_returns_bool_test() {
  let sql =
    "-- name: HasAnyKey :one\nSELECT id, metadata ?| '{a,b}' AS any_key FROM events WHERE id = $1;"
  let query = analyze_one(sql, extended_catalog())
  let assert [_id, model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.BoolType)
}

// --- Batch 3: UPSERT (INSERT ... ON CONFLICT ... [DO UPDATE SET ...] RETURNING) ---

pub fn upsert_with_excluded_reference_test() {
  // Pure ON CONFLICT DO UPDATE SET col = EXCLUDED.col flow.
  // Params come from VALUES only; the EXCLUDED reference is not a
  // placeholder so it must not derail param inference.
  let sql =
    "-- name: UpsertAuthor :one\nINSERT INTO authors (id, name, bio) VALUES ($1, $2, $3) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, bio = EXCLUDED.bio RETURNING id, name, bio;"
  let query = analyze_one(sql, test_catalog())
  // Result columns from RETURNING
  let assert [
    model.ScalarResult(id_col),
    model.ScalarResult(name_col),
    model.ScalarResult(bio_col),
  ] = query.result_columns
  id_col.name |> should.equal("id")
  id_col.scalar_type |> should.equal(model.IntType)
  name_col.scalar_type |> should.equal(model.StringType)
  bio_col.scalar_type |> should.equal(model.StringType)
  // Three params, all from VALUES
  query.params
  |> should.equal([
    model.QueryParam(
      index: 1,
      field_name: "id",
      scalar_type: model.IntType,
      nullable: False,
      is_list: False,
    ),
    model.QueryParam(
      index: 2,
      field_name: "name",
      scalar_type: model.StringType,
      nullable: False,
      is_list: False,
    ),
    model.QueryParam(
      index: 3,
      field_name: "bio",
      scalar_type: model.StringType,
      nullable: True,
      is_list: False,
    ),
  ])
}

pub fn upsert_do_nothing_test() {
  // ON CONFLICT DO NOTHING — no UPDATE, just suppresses the error.
  let sql =
    "-- name: InsertOrIgnore :one\nINSERT INTO authors (id, name) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING RETURNING id, name;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.name |> should.equal("id")
  name_col.name |> should.equal("name")
  query.params |> list.length |> should.equal(2)
}

pub fn upsert_with_set_placeholder_test() {
  // UPDATE SET name = $3 introduces a third placeholder beyond the
  // two in VALUES.
  let sql =
    "-- name: UpsertNameOverride :one\nINSERT INTO authors (id, name) VALUES ($1, $2) ON CONFLICT (id) DO UPDATE SET name = $3 RETURNING id, name;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.name |> should.equal("id")
  name_col.name |> should.equal("name")
  // Three placeholders end up in the param list. param_count from the
  // parser counts placeholder tokens; the SET-clause $3 must be picked
  // up here too.
  query.params |> list.length |> should.equal(3)
}

pub fn sqlite_upsert_with_excluded_test() {
  // SQLite syntax: ON CONFLICT(col) DO UPDATE SET col = excluded.col
  let naming_ctx = naming.new()
  let assert Ok(content) =
    simplifile.read("test/fixtures/sqlite_extended_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files_with_engine(
      [#("schema.sql", content)],
      model.SQLite,
    )
  let sql =
    "-- name: UpsertAuthorSqlite :one\nINSERT INTO authors (id, name, bio) VALUES (?1, ?2, ?3) ON CONFLICT(id) DO UPDATE SET name = excluded.name RETURNING id, name, bio;"
  let assert Ok(queries) =
    query_parser.parse_file("u.sql", model.SQLite, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)
  let assert [query] = analyzed
  let assert [
    model.ScalarResult(id_col),
    model.ScalarResult(_name),
    model.ScalarResult(_bio),
  ] = query.result_columns
  id_col.name |> should.equal("id")
  query.params |> list.length |> should.equal(3)
}

// --- Batch 4: USING clause, window FRAME, UNION compound, VALUES in FROM ---

pub fn join_using_clause_test() {
  // JOIN ... USING (col) is the SQL-standard equivalent of
  // ON a.col = b.col. The column list inside USING(...) must not
  // confuse table extraction or result column resolution.
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: BookAuthors :many\nSELECT books.title, authors.name FROM books JOIN authors USING (id);"
  let assert Ok(queries) =
    query_parser.parse_file("u.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [model.ScalarResult(title), model.ScalarResult(name)] =
    query.result_columns
  title.name |> should.equal("title")
  name.name |> should.equal("name")
}

pub fn window_function_with_frame_clause_test() {
  // SUM(x) OVER (PARTITION BY y ORDER BY z ROWS BETWEEN N PRECEDING
  // AND CURRENT ROW) — frame keywords (rows, between, preceding,
  // following, current, unbounded) must not derail the analyzer.
  let sql =
    "-- name: RunningTotal :many\nSELECT id, SUM(id) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running FROM authors;"
  let query = analyze_one(sql, test_catalog())
  let assert [_id, model.ScalarResult(running_col)] = query.result_columns
  running_col.name |> should.equal("running")
  running_col.scalar_type |> should.equal(model.IntType)
}

pub fn window_function_with_partition_and_range_test() {
  // RANGE BETWEEN ... AND ... is the alternative frame mode.
  let sql =
    "-- name: GroupedRank :many\nSELECT id, RANK() OVER (PARTITION BY name ORDER BY id RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_rank FROM authors;"
  let query = analyze_one(sql, test_catalog())
  let assert [_id, model.ScalarResult(rank_col)] = query.result_columns
  rank_col.name |> should.equal("grp_rank")
  rank_col.scalar_type |> should.equal(model.IntType)
}

pub fn union_takes_types_from_first_branch_test() {
  // Compound queries (UNION / INTERSECT / EXCEPT) currently use the
  // first branch's column types. Types in subsequent branches are not
  // matched (SQL itself errors at execution time on mismatch).
  let sql =
    "-- name: AllNames :many\nSELECT name FROM authors UNION SELECT name FROM authors;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(name_col)] = query.result_columns
  name_col.name |> should.equal("name")
  name_col.scalar_type |> should.equal(model.StringType)
}

pub fn union_all_works_test() {
  let sql =
    "-- name: AllNamesAll :many\nSELECT name FROM authors UNION ALL SELECT name FROM authors;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(name_col)] = query.result_columns
  name_col.name |> should.equal("name")
}

pub fn intersect_works_test() {
  let sql =
    "-- name: SharedNames :many\nSELECT name FROM authors INTERSECT SELECT name FROM authors;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(name_col)] = query.result_columns
  name_col.name |> should.equal("name")
}

pub fn compound_column_count_mismatch_errors_test() {
  // Branches with different column counts must error out at analysis
  // time, before code generation.
  let naming_ctx = naming.new()
  let sql =
    "-- name: Bad :many\nSELECT id, name FROM authors UNION SELECT name FROM authors;"
  let assert Ok(queries) =
    query_parser.parse_file("bad.sql", model.PostgreSQL, naming_ctx, sql)
  let result =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      test_catalog(),
      naming_ctx,
      queries,
    )
  case result {
    Error(context.CompoundColumnCountMismatch(..)) -> Nil
    _ -> panic as "expected CompoundColumnCountMismatch"
  }
}

// --- Batch 7: WITH (CTE) and WITH RECURSIVE result column inference ---

pub fn with_cte_table_lookup_test() {
  // Plain CTE: `WITH cte AS (SELECT ...) SELECT cols FROM cte`. The
  // CTE name acts as a virtual table whose columns come from the
  // CTE body's SELECT list.
  let sql =
    "-- name: ActiveAuthors :many\nWITH active AS (SELECT id, name FROM authors) SELECT id, name FROM active;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.name |> should.equal("id")
  id_col.scalar_type |> should.equal(model.IntType)
  name_col.name |> should.equal("name")
  name_col.scalar_type |> should.equal(model.StringType)
}

pub fn with_recursive_anchor_columns_test() {
  // RECURSIVE: column types come from the anchor (first) branch of
  // the UNION ALL. The recursive branch references the CTE itself.
  let sql =
    "-- name: AuthorChain :many\nWITH RECURSIVE chain AS (SELECT id, name FROM authors WHERE id = 1 UNION ALL SELECT id, name FROM authors WHERE id > 1) SELECT id, name FROM chain;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.scalar_type |> should.equal(model.IntType)
  name_col.scalar_type |> should.equal(model.StringType)
}

// --- Batch 8: LATERAL JOIN / correlated subqueries ---

pub fn lateral_join_keyword_does_not_break_test() {
  // `JOIN LATERAL (subquery)` — at minimum the LATERAL keyword and
  // the subquery must not derail outer SELECT inference. The outer
  // table's columns must still be resolved.
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: BookFirstAuthor :many\nSELECT books.title FROM books LEFT JOIN LATERAL (SELECT name FROM authors WHERE authors.id = books.author_id LIMIT 1) AS first_author ON true;"
  let assert Ok(queries) =
    query_parser.parse_file("l.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [model.ScalarResult(title_col)] = query.result_columns
  title_col.name |> should.equal("title")
}

pub fn correlated_subquery_in_select_test() {
  // Correlated scalar subquery in SELECT. The outer column reference
  // (posts.author_id) inside the subquery must not break the outer
  // analysis. Result type of the subquery is the subquery's column.
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: PostsWithAuthorName :many\nSELECT books.title, (SELECT name FROM authors WHERE authors.id = books.author_id) AS author_name FROM books;"
  let assert Ok(queries) =
    query_parser.parse_file("c.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [model.ScalarResult(title), model.ScalarResult(author_name)] =
    query.result_columns
  title.name |> should.equal("title")
  author_name.name |> should.equal("author_name")
  // Subquery results are nullable (zero rows possible).
  author_name.scalar_type |> should.equal(model.StringType)
  author_name.nullable |> should.equal(True)
}

pub fn cte_with_explicit_column_list_test() {
  // `WITH name(c1, c2) AS (...)` — the explicit column list renames
  // the CTE's columns. Types and nullability come from the body, but
  // the outer query must reference the new names.
  let sql =
    "-- name: AliasedCte :many\nWITH renamed(x, y) AS (SELECT id, name FROM authors) SELECT x, y FROM renamed;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(x_col), model.ScalarResult(y_col)] =
    query.result_columns
  x_col.name |> should.equal("x")
  x_col.scalar_type |> should.equal(model.IntType)
  y_col.name |> should.equal("y")
  y_col.scalar_type |> should.equal(model.StringType)
}

pub fn multiple_ctes_chain_test() {
  // Multiple CTEs separated by commas; later CTEs may reference
  // earlier ones.
  let sql =
    "-- name: ChainedCte :many\nWITH a AS (SELECT id, name FROM authors), b AS (SELECT id, name FROM a) SELECT id, name FROM b;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.scalar_type |> should.equal(model.IntType)
  name_col.scalar_type |> should.equal(model.StringType)
}

pub fn exists_subquery_returns_bool_test() {
  // EXISTS (SELECT ...) was already handled by the boolean pattern;
  // pin it here so the subquery extension does not regress it. We
  // include an outer FROM because result-column resolution needs a
  // primary table.
  let sql =
    "-- name: HasAuthors :one\nSELECT id, EXISTS (SELECT 1 FROM authors WHERE id = 1) AS has_any FROM authors WHERE id = 1;"
  let query = analyze_one(sql, test_catalog())
  let assert [_id, model.ScalarResult(col)] = query.result_columns
  col.name |> should.equal("has_any")
  col.scalar_type |> should.equal(model.BoolType)
}

pub fn values_in_from_infers_columns_test() {
  // `FROM (VALUES ...) AS t(id, name)` becomes a virtual table whose
  // column types come from the first row's literal types and whose
  // names come from the alias column list.
  let sql =
    "-- name: FromValues :many\nSELECT t.id, t.name FROM (VALUES (1, 'alice'), (2, 'bob')) AS t(id, name);"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.name |> should.equal("id")
  id_col.scalar_type |> should.equal(model.IntType)
  name_col.name |> should.equal("name")
  name_col.scalar_type |> should.equal(model.StringType)
}

pub fn values_in_from_infers_float_and_bool_test() {
  // Mix of numeric (with decimal), boolean, and string literals —
  // verifies the literal-to-ScalarType table handles the common cases.
  let sql =
    "-- name: FromMixedValues :many\nSELECT t.ratio, t.active, t.label FROM (VALUES (1.5, true, 'x')) AS t(ratio, active, label);"
  let query = analyze_one(sql, test_catalog())
  let assert [
    model.ScalarResult(ratio_col),
    model.ScalarResult(active_col),
    model.ScalarResult(label_col),
  ] = query.result_columns
  ratio_col.scalar_type |> should.equal(model.FloatType)
  active_col.scalar_type |> should.equal(model.BoolType)
  label_col.scalar_type |> should.equal(model.StringType)
}

pub fn cte_explicit_column_list_renames_partially_test() {
  // Fewer explicit names than body columns: only the first N get
  // renamed; the rest keep their original names. This mirrors how the
  // query would behave if the user under-specified on purpose.
  let sql =
    "-- name: PartialRename :many\nWITH t(alias_id) AS (SELECT id, name FROM authors) SELECT alias_id, name FROM t;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(alias_col), model.ScalarResult(name_col)] =
    query.result_columns
  alias_col.name |> should.equal("alias_id")
  alias_col.scalar_type |> should.equal(model.IntType)
  name_col.name |> should.equal("name")
  name_col.scalar_type |> should.equal(model.StringType)
}

pub fn correlated_subquery_outer_only_column_test() {
  // The inner SELECT has no FROM of its own, so its column reference
  // (`books.title`) must be resolved from the enclosing query's FROM
  // list. This exercises the outer-scope fallback in
  // infer_columns_from_tokens_scoped.
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: EchoTitle :many\nSELECT books.title, (SELECT books.title) AS echoed FROM books;"
  let assert Ok(queries) =
    query_parser.parse_file("e.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [model.ScalarResult(title), model.ScalarResult(echoed)] =
    query.result_columns
  title.scalar_type |> should.equal(model.StringType)
  echoed.scalar_type |> should.equal(model.StringType)
  echoed.nullable |> should.equal(True)
}

// --- #324: derived tables in FROM / JOIN ---

pub fn derived_table_in_from_body_names_test() {
  // `FROM (SELECT id, name FROM authors) AS sub` — no explicit column
  // list, so the derived table's columns come from the inner SELECT
  // and are reachable via the alias.
  let sql =
    "-- name: FromDerived :many\nSELECT sub.id, sub.name FROM (SELECT id, name FROM authors) AS sub;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col), model.ScalarResult(name_col)] =
    query.result_columns
  id_col.name |> should.equal("id")
  id_col.scalar_type |> should.equal(model.IntType)
  name_col.name |> should.equal("name")
  name_col.scalar_type |> should.equal(model.StringType)
}

pub fn derived_table_with_explicit_column_list_test() {
  // The alias column list `s(x, y)` renames the inferred columns; the
  // outer SELECT must reference the new names.
  let sql =
    "-- name: FromDerivedAliased :many\nSELECT s.x, s.y FROM (SELECT id, name FROM authors) AS s(x, y);"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(x_col), model.ScalarResult(y_col)] =
    query.result_columns
  x_col.name |> should.equal("x")
  x_col.scalar_type |> should.equal(model.IntType)
  y_col.name |> should.equal("y")
  y_col.scalar_type |> should.equal(model.StringType)
}

pub fn derived_table_in_join_test() {
  // Derived table joined onto a real table. The inner SELECT computes
  // `author_id` and an aggregated column, and the outer SELECT pulls
  // columns from both sides.
  let naming_ctx = naming.new()
  let catalog = join_catalog()
  let sql =
    "-- name: AuthorsWithPostCount :many\nSELECT authors.name, sub.total FROM authors JOIN (SELECT author_id, COUNT(*) AS total FROM books GROUP BY author_id) AS sub ON authors.id = sub.author_id;"
  let assert Ok(queries) =
    query_parser.parse_file("d.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [model.ScalarResult(name_col), model.ScalarResult(total_col)] =
    query.result_columns
  name_col.scalar_type |> should.equal(model.StringType)
  total_col.name |> should.equal("total")
  total_col.scalar_type |> should.equal(model.IntType)
}

pub fn derived_table_nested_test() {
  // `FROM (SELECT * FROM (SELECT ...) AS inner) AS outer` — the inner
  // derived table must be discovered and augmented before the outer
  // body's resolver runs.
  let sql =
    "-- name: Nested :many\nSELECT outer_alias.id FROM (SELECT inner_alias.id FROM (SELECT id, name FROM authors) AS inner_alias) AS outer_alias;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(id_col)] = query.result_columns
  id_col.scalar_type |> should.equal(model.IntType)
}

pub fn derived_table_referencing_cte_test() {
  // A derived table's body can reference a CTE defined in the same
  // query, because extract_derived_tables runs against the catalog
  // already augmented with CTE virtual tables.
  let sql =
    "-- name: DerivedOverCte :many\nWITH c AS (SELECT id, name FROM authors) SELECT d.name FROM (SELECT name FROM c) AS d;"
  let query = analyze_one(sql, test_catalog())
  let assert [model.ScalarResult(name_col)] = query.result_columns
  name_col.name |> should.equal("name")
  name_col.scalar_type |> should.equal(model.StringType)
}

pub fn mysql_on_duplicate_key_update_test() {
  // MySQL: INSERT ... ON DUPLICATE KEY UPDATE col = VALUES(col)
  // Param count should be 2 (from the INSERT VALUES); VALUES(col) on
  // the right side is a MySQL function reference, not a placeholder.
  // Use the catalog from authors-style fixture.
  let naming_ctx = naming.new()
  let catalog =
    model.Catalog(
      tables: [
        model.Table(name: "items", columns: [
          model.Column(name: "id", scalar_type: model.IntType, nullable: False),
          model.Column(
            name: "name",
            scalar_type: model.StringType,
            nullable: False,
          ),
        ]),
      ],
      enums: [],
    )
  let sql =
    "-- name: UpsertItem :exec\nINSERT INTO items (id, name) VALUES (?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name);"
  let assert Ok(queries) =
    query_parser.parse_file("u.sql", model.MySQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.MySQL, catalog, naming_ctx, queries)
  let assert [query] = analyzed
  query.params |> list.length |> should.equal(2)
}

// ------------------------------------------------------------
// Engine-aware expression parser (Issue #405)
// ------------------------------------------------------------

/// MySQL `ON DUPLICATE KEY UPDATE` is captured as first-class IR state
/// on `InsertStmt`, not silently skipped. Asserting on the assignment
/// column names confirms the clause survived parsing.
pub fn expr_parser_preserves_mysql_on_duplicate_key_update_test() {
  let sql =
    "INSERT INTO items (id, name) VALUES (?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name);"
  let tokens = lexer.tokenize(sql, model.MySQL)
  let stmt = expr_parser.parse_stmt(tokens, model.MySQL)
  let assert query_ir.InsertStmt(on_duplicate_key_update: assignments, ..) =
    stmt
  assignments
  |> list.map(fn(assignment) { assignment.column })
  |> should.equal(["name"])
}

/// For non-MySQL engines the same token stream must not invent any
/// upsert assignments — the clause is simply absent from the IR so
/// downstream passes do not emit MySQL-specific code on PostgreSQL.
pub fn expr_parser_skips_on_duplicate_key_update_for_postgresql_test() {
  let sql =
    "INSERT INTO items (id, name) VALUES ($1, $2) ON DUPLICATE KEY UPDATE name = VALUES(name);"
  let tokens = lexer.tokenize(sql, model.PostgreSQL)
  let stmt = expr_parser.parse_stmt(tokens, model.PostgreSQL)
  let assert query_ir.InsertStmt(on_duplicate_key_update: assignments, ..) =
    stmt
  assignments |> should.equal([])
}

/// MySQL's `LIMIT offset, count` two-argument syntax is the reverse of
/// PostgreSQL's `LIMIT count OFFSET offset`: the first expression is
/// the offset and the second is the row limit. The parser has to notice
/// the top-level comma and populate `offset` / `limit` in that order.
pub fn expr_parser_mysql_limit_offset_count_test() {
  let sql = "SELECT id FROM items LIMIT 10, 5;"
  let tokens = lexer.tokenize(sql, model.MySQL)
  let #(core, _rest) = expr_parser.parse_select_core(tokens, model.MySQL)
  case core.offset {
    Some(query_ir.NumberLit(value)) -> value |> should.equal("10")
    other -> should.equal(other, Some(query_ir.NumberLit(value: "10")))
  }
  case core.limit {
    Some(query_ir.NumberLit(value)) -> value |> should.equal("5")
    other -> should.equal(other, Some(query_ir.NumberLit(value: "5")))
  }
}

/// PostgreSQL keeps its canonical `LIMIT count OFFSET offset` semantic.
/// This pins the non-MySQL branch so the MySQL swap above cannot
/// regress the default behaviour.
pub fn expr_parser_postgresql_limit_offset_test() {
  let sql = "SELECT id FROM items LIMIT 5 OFFSET 10;"
  let tokens = lexer.tokenize(sql, model.PostgreSQL)
  let #(core, _rest) = expr_parser.parse_select_core(tokens, model.PostgreSQL)
  case core.limit {
    Some(query_ir.NumberLit(value)) -> value |> should.equal("5")
    other -> should.equal(other, Some(query_ir.NumberLit(value: "5")))
  }
  case core.offset {
    Some(query_ir.NumberLit(value)) -> value |> should.equal("10")
    other -> should.equal(other, Some(query_ir.NumberLit(value: "10")))
  }
}

// ------------------------------------------------------------
// Branch-aware arithmetic and CASE inference tests (Issue #363)
// ------------------------------------------------------------

fn pricing_catalog() -> model.Catalog {
  model.Catalog(
    tables: [
      model.Table(name: "items", columns: [
        model.Column(name: "id", scalar_type: model.IntType, nullable: False),
        model.Column(
          name: "price",
          scalar_type: model.FloatType,
          nullable: False,
        ),
        model.Column(
          name: "discount",
          scalar_type: model.FloatType,
          nullable: True,
        ),
        model.Column(
          name: "quantity",
          scalar_type: model.IntType,
          nullable: False,
        ),
      ]),
    ],
    enums: [],
  )
}

fn analyze_single(sql: String, catalog: model.Catalog) -> model.AnalyzedQuery {
  let naming_ctx = naming.new()
  let assert Ok(queries) =
    query_parser.parse_file("t.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  query
}

pub fn arithmetic_promotes_int_to_float_test() {
  let query =
    analyze_single(
      "-- name: Total :one\nSELECT id + 1.5 AS total FROM authors WHERE id = $1;",
      test_catalog(),
    )
  let assert [model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.FloatType)
  col.nullable |> should.be_false()
}

pub fn arithmetic_price_math_stays_float_test() {
  let query =
    analyze_single(
      "-- name: LineTotal :many\nSELECT price * quantity AS line_total FROM items;",
      pricing_catalog(),
    )
  let assert [model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.FloatType)
  col.nullable |> should.be_false()
}

pub fn arithmetic_propagates_nullable_operand_test() {
  let query =
    analyze_single(
      "-- name: NetPrice :many\nSELECT price - discount AS net FROM items;",
      pricing_catalog(),
    )
  let assert [model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.FloatType)
  col.nullable |> should.be_true()
}

pub fn arithmetic_int_operands_stay_int_test() {
  let query =
    analyze_single(
      "-- name: Doubled :many\nSELECT quantity * 2 AS doubled FROM items;",
      pricing_catalog(),
    )
  let assert [model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.IntType)
  col.nullable |> should.be_false()
}

pub fn case_unifies_int_and_float_branches_test() {
  let query =
    analyze_single(
      "-- name: Mixed :many
SELECT CASE WHEN id = 1 THEN 1 WHEN id = 2 THEN 2.5 ELSE 3 END AS value FROM items;",
      pricing_catalog(),
    )
  let assert [model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.FloatType)
  col.nullable |> should.be_false()
}

pub fn case_without_else_is_nullable_test() {
  let query =
    analyze_single(
      "-- name: Opt :many
SELECT CASE WHEN id = 1 THEN 10 END AS maybe FROM items;",
      pricing_catalog(),
    )
  let assert [model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.IntType)
  col.nullable |> should.be_true()
}

pub fn case_with_else_not_null_is_not_nullable_test() {
  let query =
    analyze_single(
      "-- name: Strict :many
SELECT CASE WHEN id = 1 THEN 10 ELSE 20 END AS value FROM items;",
      pricing_catalog(),
    )
  let assert [model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.IntType)
  col.nullable |> should.be_false()
}

pub fn case_with_null_branch_is_nullable_test() {
  let query =
    analyze_single(
      "-- name: WithNull :many
SELECT CASE WHEN id = 1 THEN NULL ELSE 42 END AS value FROM items;",
      pricing_catalog(),
    )
  let assert [model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.IntType)
  col.nullable |> should.be_true()
}

pub fn case_nested_inherits_unified_type_test() {
  let query =
    analyze_single(
      "-- name: Nested :many
SELECT CASE WHEN id = 1 THEN CASE WHEN quantity > 0 THEN 1.0 ELSE 2 END ELSE 3 END AS value FROM items;",
      pricing_catalog(),
    )
  let assert [model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.FloatType)
  col.nullable |> should.be_false()
}

pub fn case_nullable_column_branch_propagates_test() {
  let query =
    analyze_single(
      "-- name: MaybeDiscount :many
SELECT CASE WHEN id = 1 THEN discount ELSE 0.0 END AS value FROM items;",
      pricing_catalog(),
    )
  let assert [model.ScalarResult(col)] = query.result_columns
  col.scalar_type |> should.equal(model.FloatType)
  col.nullable |> should.be_true()
}

// --- Structured IR tests ---

pub fn structure_tokens_select_test() {
  let tokens =
    lexer.tokenize(
      "SELECT id, name FROM authors WHERE id = $1",
      model.PostgreSQL,
    )
  let statement = token_utils.structure_tokens(tokens)
  case statement {
    query_ir.SelectStatement(select_items:, from:, ..) -> {
      list.length(select_items) |> should.equal(2)
      list.length(from) |> should.equal(1)
    }
    _ -> should.fail()
  }
}

pub fn structure_tokens_insert_test() {
  let tokens =
    lexer.tokenize(
      "INSERT INTO authors (name, bio) VALUES ($1, $2)",
      model.PostgreSQL,
    )
  let statement = token_utils.structure_tokens(tokens)
  case statement {
    query_ir.InsertStatement(table_name:, columns:, value_groups:, ..) -> {
      table_name |> should.equal("authors")
      list.length(columns) |> should.equal(2)
      list.length(value_groups) |> should.equal(2)
    }
    _ -> should.fail()
  }
}

pub fn structure_tokens_update_test() {
  let tokens =
    lexer.tokenize(
      "UPDATE authors SET name = $1 WHERE id = $2",
      model.PostgreSQL,
    )
  let statement = token_utils.structure_tokens(tokens)
  case statement {
    query_ir.UpdateStatement(table_name:, ..) -> {
      table_name |> should.equal("authors")
    }
    _ -> should.fail()
  }
}

pub fn structure_tokens_delete_test() {
  let tokens =
    lexer.tokenize("DELETE FROM authors WHERE id = $1", model.PostgreSQL)
  let statement = token_utils.structure_tokens(tokens)
  case statement {
    query_ir.DeleteStatement(table_name:, ..) -> {
      table_name |> should.equal("authors")
    }
    _ -> should.fail()
  }
}

pub fn structure_tokens_with_cte_test() {
  let tokens =
    lexer.tokenize(
      "WITH active AS (SELECT * FROM authors WHERE active = true) SELECT id FROM active",
      model.PostgreSQL,
    )
  let statement = token_utils.structure_tokens(tokens)
  case statement {
    query_ir.SelectStatement(..) -> Nil
    _ -> should.fail()
  }
}

pub fn param_type_conflict_detection_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: ConflictTest :one
SELECT id FROM authors WHERE id = $1 AND name = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("conflict.sql", model.PostgreSQL, naming_ctx, sql)
  let result =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert Error(context.ParameterTypeConflict(
    query_name: "ConflictTest",
    param_index: 1,
    type_a: model.IntType,
    type_b: model.StringType,
  )) = result
}

pub fn ambiguous_unqualified_param_column_is_rejected_test() {
  // Regression for Issue #390. A CTE-joined query with three `id`
  // columns in scope (`memberships.id`, `active_users.id`,
  // `teams.id`) must surface an AmbiguousColumnName error for
  // `WHERE id = $1` instead of silently binding to the primary
  // table's id column.
  let naming_ctx = naming.new()
  let assert Ok(schema_content) =
    simplifile.read("test/fixtures/ambiguous_param_schema.sql")
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([
      #("test/fixtures/ambiguous_param_schema.sql", schema_content),
    ])

  let assert Ok(sql) =
    simplifile.read("test/fixtures/ambiguous_param_query.sql")
  let assert Ok(queries) =
    query_parser.parse_file(
      "test/fixtures/ambiguous_param_query.sql",
      model.PostgreSQL,
      naming_ctx,
      sql,
    )

  let result =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Error(context.AmbiguousColumnName(
    query_name: "GetMembership",
    column_name: "id",
    matching_tables: tables,
  )) = result
  // The matching list must contain every table that exposes `id` at
  // the outermost FROM/JOIN scope. CTE-internal references do not
  // leak here thanks to the WITH-prefix strip, so we assert on the
  // three top-level tables.
  list.contains(tables, "memberships") |> should.be_true()
  list.contains(tables, "active_users") |> should.be_true()
  list.contains(tables, "teams") |> should.be_true()
}

// --- IR-based equality walker tests (Issue #406) ---
//
// These queries exercise the `find_equality_matches_in_stmt` walker
// that `infer_equality_params` now prefers over the token-based
// `find_equality_patterns`. Each case is driven through the public
// `query_analyzer.analyze_queries` pipeline so the wiring is covered
// end-to-end, not just the helper in isolation.

pub fn ir_walker_infers_multiple_equality_params_in_order_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetByIdAndName :one
SELECT id, name FROM authors WHERE id = $1 AND name = $2;"
  let assert Ok(queries) =
    query_parser.parse_file("eq.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  query.params
  |> should.equal([
    model.QueryParam(
      index: 1,
      field_name: "id",
      scalar_type: model.IntType,
      nullable: False,
      is_list: False,
    ),
    model.QueryParam(
      index: 2,
      field_name: "name",
      scalar_type: model.StringType,
      nullable: False,
      is_list: False,
    ),
  ])
}

pub fn ir_walker_resolves_qualified_equality_param_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetByQualifiedId :one
SELECT id, name FROM authors AS a WHERE a.id = $1;"
  let assert Ok(queries) =
    query_parser.parse_file("qualified.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [param] = query.params
  param.index |> should.equal(1)
  param.field_name |> should.equal("id")
  param.scalar_type |> should.equal(model.IntType)
}

pub fn ir_walker_infers_like_predicate_param_test() {
  // `WHERE name LIKE $1` must infer $1 as the column's type via the
  // IR `LikeExpr(ColumnRef, _, Param, …)` branch. The pre-refactor
  // token scanner covered this via its `column LIKE placeholder`
  // patterns; the IR walker must match exactly.
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: SearchByName :many
SELECT id, name FROM authors WHERE name LIKE $1;"
  let assert Ok(queries) =
    query_parser.parse_file("like.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [param] = query.params
  param.index |> should.equal(1)
  param.field_name |> should.equal("name")
  param.scalar_type |> should.equal(model.StringType)
}

pub fn ir_walker_handles_reversed_operand_order_test() {
  // `$1 = id` binds `id` just like `id = $1` — the walker handles both
  // `Binary(_, ColumnRef, Param)` and `Binary(_, Param, ColumnRef)`.
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetByReversedId :one
SELECT id, name FROM authors WHERE $1 = id;"
  let assert Ok(queries) =
    query_parser.parse_file("reversed.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [param] = query.params
  param.index |> should.equal(1)
  param.field_name |> should.equal("id")
  param.scalar_type |> should.equal(model.IntType)
}

// --- IR-based IN / quantified walker tests (Issue #406) ---
//
// These queries exercise the `find_in_quantified_matches_in_stmt`
// walker that `infer_in_params` now prefers over the token-based
// `find_in_patterns` / `find_quantified_patterns`. Each case is driven
// through the public `query_analyzer.analyze_queries` pipeline so the
// wiring is covered end-to-end.

/// Pin the IR path for the IN / quantified walker tests. Without this
/// a future regression that made `expr_parser.parse_stmt` return
/// `UnstructuredStmt` would silently fall back to the token scanner,
/// letting the test still pass through the legacy path.
fn assert_ir_select(sql: String) -> Nil {
  let stmt =
    expr_parser.parse_stmt(
      lexer.tokenize(sql, model.PostgreSQL),
      model.PostgreSQL,
    )
  case stmt {
    query_ir.SelectStmt(..) -> Nil
    _ -> panic as "expected SelectStmt from expr_parser.parse_stmt"
  }
}

pub fn ir_walker_infers_single_element_in_param_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetAuthorsByIdList :many
SELECT id, name FROM authors WHERE id IN ($1);"
  assert_ir_select(sql)
  let assert Ok(queries) =
    query_parser.parse_file("in.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [param] = query.params
  param.index |> should.equal(1)
  param.field_name |> should.equal("id")
  param.scalar_type |> should.equal(model.IntType)
}

pub fn ir_walker_infers_qualified_in_param_test() {
  // Qualified `a.id IN ($1)` must carry the table qualifier through
  // so the column is looked up under `authors` (aliased as `a`).
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetQualifiedAuthorsById :many
SELECT a.id, a.name FROM authors AS a WHERE a.id IN ($1);"
  assert_ir_select(sql)
  let assert Ok(queries) =
    query_parser.parse_file(
      "in_qualified.sql",
      model.PostgreSQL,
      naming_ctx,
      sql,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [param] = query.params
  param.index |> should.equal(1)
  param.field_name |> should.equal("id")
  param.scalar_type |> should.equal(model.IntType)
}

pub fn ir_walker_infers_quantified_any_param_test() {
  // PostgreSQL-style `WHERE col = ANY($1)` resolves $1 via the
  // `Quantified(ColumnRef, QAny, Param)` branch of the walker.
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetAuthorsAnyId :many
SELECT id, name FROM authors WHERE id = ANY($1);"
  assert_ir_select(sql)
  let assert Ok(queries) =
    query_parser.parse_file("any.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  let assert [param] = query.params
  param.index |> should.equal(1)
  param.field_name |> should.equal("id")
  param.scalar_type |> should.equal(model.IntType)
}

pub fn ir_walker_infers_update_assignment_in_subquery_test() {
  // The IR walker for UPDATE must descend into each assignment's
  // value expression: `UPDATE authors SET bio = (SELECT bio FROM
  // authors WHERE id IN ($1)) WHERE id = $2`. $1 is the IN
  // placeholder inside the scalar-subquery RHS of the assignment,
  // which the previous walker (WHERE-only) would have missed.
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: UpdateBioFromId :exec
UPDATE authors SET bio = (SELECT bio FROM authors WHERE id IN ($1)) WHERE id = $2;"
  let assert Ok(queries) =
    query_parser.parse_file(
      "update_in_subquery.sql",
      model.PostgreSQL,
      naming_ctx,
      sql,
    )
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  // $1 (inner IN) and $2 (outer equality) should both bind to `id`.
  let assert [p1, p2] = query.params
  p1.index |> should.equal(1)
  p1.field_name |> should.equal("id")
  p1.scalar_type |> should.equal(model.IntType)
  p2.index |> should.equal(2)
  p2.field_name |> should.equal("id")
  p2.scalar_type |> should.equal(model.IntType)
}

pub fn ir_walker_skips_in_subquery_test() {
  // `id IN (SELECT …)` is the subquery form — the walker must not
  // emit an IN match for it (subquery inference is the subquery's
  // own job). The test merely confirms analysis still succeeds.
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetAuthorsByIdSub :many
SELECT id, name FROM authors WHERE id IN (SELECT id FROM authors WHERE name = $1);"
  assert_ir_select(sql)
  let assert Ok(queries) =
    query_parser.parse_file("in_sub.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  // Only $1 (the inner `name = $1` equality) should surface; there's
  // no standalone single-element IN placeholder to bind.
  let assert [param] = query.params
  param.index |> should.equal(1)
  param.field_name |> should.equal("name")
  param.scalar_type |> should.equal(model.StringType)
}

// ============================================================
// Issue #406: IR-driven virtual-table scope integration tests.
//
// Each of the four IR extractors (CTE / VALUES / derived / alias)
// gets a realistic query that is driven through the full
// `query_analyzer.analyze_queries` pipeline. `assert_ir_select`
// pins that `expr_parser.parse_stmt` produced a structured Stmt
// (not UnstructuredStmt), guaranteeing the IR path is exercised
// rather than the token fallback.
// ============================================================

pub fn ir_cte_virtual_table_resolves_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetCteIds :many
WITH cte AS (SELECT id FROM authors) SELECT id FROM cte;"
  assert_ir_select(sql)
  let assert Ok(queries) =
    query_parser.parse_file("cte.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  query.result_columns
  |> should.equal([
    model.ScalarResult(model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("cte"),
    )),
  ])
}

pub fn ir_values_virtual_table_infers_param_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetValuesRows :many
SELECT n FROM (VALUES (1), (2)) AS v(n) WHERE n > $1;"
  assert_ir_select(sql)
  let assert Ok(queries) =
    query_parser.parse_file("values.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  // Result column `n` resolves through the VALUES virtual table as IntType.
  let assert [model.ScalarResult(col)] = query.result_columns
  col.name |> should.equal("n")
  col.scalar_type |> should.equal(model.IntType)
  // The $1 placeholder compared against `n` must infer IntType too.
  let assert [param] = query.params
  param.index |> should.equal(1)
  param.field_name |> should.equal("n")
  param.scalar_type |> should.equal(model.IntType)
}

pub fn ir_derived_table_virtual_resolves_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: GetDerivedIds :many
SELECT t.id FROM (SELECT id FROM authors) AS t;"
  assert_ir_select(sql)
  let assert Ok(queries) =
    query_parser.parse_file("derived.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  // The column resolves through the derived-table alias `t`, whose
  // columns are inferred from the subquery body.
  let assert [model.ScalarResult(col)] = query.result_columns
  col.name |> should.equal("id")
  col.scalar_type |> should.equal(model.IntType)
}

pub fn ir_table_alias_resolves_qualified_column_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql = "-- name: GetAliasedIds :many\nSELECT a.id FROM authors AS a;"
  assert_ir_select(sql)
  let assert Ok(queries) =
    query_parser.parse_file("alias.sql", model.PostgreSQL, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let assert [query] = analyzed
  // `a.id` must resolve via the `authors AS a` alias back to `authors`.
  let assert [model.ScalarResult(col)] = query.result_columns
  col.name |> should.equal("id")
  col.scalar_type |> should.equal(model.IntType)
}
