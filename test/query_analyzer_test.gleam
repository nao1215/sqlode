import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer
import sqlode/query_analyzer/context
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
    model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    ),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    ),
  ])

  list_authors.result_columns
  |> should.equal([
    model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    ),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    ),
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
    model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    ),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    ),
    model.ResultColumn(
      name: "bio",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("authors"),
    ),
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
    model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    ),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    ),
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
    "CREATE TYPE status AS ENUM ('active', 'inactive', 'banned');\n"
    <> "CREATE TABLE users (\n"
    <> "  id BIGSERIAL PRIMARY KEY,\n"
    <> "  name TEXT NOT NULL,\n"
    <> "  status status NOT NULL\n"
    <> ");"

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
    model.ResultColumn(
      name: "title",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("books"),
    ),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    ),
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

  let assert [embed_col, title_col] = query.result_columns
  let assert model.EmbeddedColumn(name: embed_name, table_name:, columns:) =
    embed_col
  embed_name |> should.equal("authors")
  table_name |> should.equal("authors")
  list.length(columns) |> should.equal(3)
  title_col.name |> should.equal("title")
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
    model.ResultColumn(
      name: "id",
      scalar_type: model.IntType,
      nullable: False,
      source_table: Some("authors"),
    ),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    ),
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
  |> should.equal(model.ResultColumn(
    name: "id",
    scalar_type: model.IntType,
    nullable: False,
    source_table: Some("authors"),
  ))
  // COALESCE(bio, name) should resolve to StringType
  display_col
  |> should.equal(model.ResultColumn(
    name: "display",
    scalar_type: model.StringType,
    nullable: False,
    source_table: None,
  ))
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

  let assert [id_col, name_col] = query.result_columns
  id_col.name |> should.equal("id")
  let assert model.ResultColumn(scalar_type: id_scalar_type, ..) = id_col
  id_scalar_type |> should.equal(model.IntType)
  name_col.name |> should.equal("name")
}

pub fn compound_query_column_count_mismatch_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let content =
    "-- name: BadUnion :many\n"
    <> "SELECT id, name FROM authors\n"
    <> "UNION\n"
    <> "SELECT id FROM authors;"

  let assert Ok(queries) =
    query_parser.parse_file("union.sql", model.PostgreSQL, naming_ctx, content)
  let assert Error(err) =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )
  let msg = query_analyzer.analysis_error_to_string(err)
  msg |> string.contains("2") |> should.be_true()
  msg |> string.contains("1") |> should.be_true()
  msg |> string.contains("BadUnion") |> should.be_true()
}

pub fn compound_query_valid_union_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let content =
    "-- name: GoodUnion :many\n"
    <> "SELECT id, name FROM authors\n"
    <> "UNION ALL\n"
    <> "SELECT id, name FROM authors;"

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
    "-- name: BadExcept :many\n"
    <> "SELECT id, name FROM authors\n"
    <> "EXCEPT\n"
    <> "SELECT id, name, bio FROM authors;"

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
  let msg = query_analyzer.analysis_error_to_string(error)
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
  let msg = query_analyzer.analysis_error_to_string(error)
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
  let msg = query_analyzer.analysis_error_to_string(error)
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
  let msg = query_analyzer.analysis_error_to_string(error)
  string.contains(msg, "BadCast") |> should.be_true()
  string.contains(msg, "geometry") |> should.be_true()
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
    model.ResultColumn(
      name: "title",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("books"),
    ),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("authors"),
    ),
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
    model.ResultColumn(
      name: "title",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("books"),
    ),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: False,
      source_table: Some("authors"),
    ),
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
    model.ResultColumn(
      name: "title",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("books"),
    ),
    model.ResultColumn(
      name: "name",
      scalar_type: model.StringType,
      nullable: True,
      source_table: Some("authors"),
    ),
  ])
}

pub fn sqlite_repeated_named_placeholder_single_param_test() {
  let naming_ctx = naming.new()
  let catalog = test_catalog()
  let sql =
    "-- name: ReusedNamed :one\n"
    <> "SELECT id FROM authors WHERE name = :name OR bio = :name;"

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
    "-- name: MixedDedup :one\n"
    <> "SELECT id FROM authors WHERE name = :name AND bio = :name AND id = :id;"

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
  let sql =
    "-- name: ReusedAt :one\n"
    <> "SELECT id FROM authors WHERE id = @id OR name = @id;"

  let assert Ok(queries) =
    query_parser.parse_file("at.sql", model.SQLite, naming_ctx, sql)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, queries)
  let assert [query] = analyzed

  list.length(query.params) |> should.equal(1)
  let assert [param] = query.params
  param.index |> should.equal(1)
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
  let assert [total_col] = count_query.result_columns
  let assert model.ResultColumn(name: "total", scalar_type: model.IntType, ..) =
    total_col
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
  let assert [sum_col, avg_col] = sum_avg_query.result_columns
  let assert model.ResultColumn(
    name: "id_sum",
    scalar_type: model.IntType,
    nullable: True,
    ..,
  ) = sum_col
  let assert model.ResultColumn(
    name: "id_avg",
    scalar_type: model.FloatType,
    nullable: True,
    ..,
  ) = avg_col
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
  let assert [_, bio_col] = coalesce_query.result_columns
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
  let assert [_, name_col] = cast_query.result_columns
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
  let assert [one_col, greeting_col] = literal_query.result_columns
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

  let assert [col] = query.result_columns
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

  let assert [col] = query.result_columns
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

  let assert [col] = query.result_columns
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

  let assert [col] = query.result_columns
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

  let assert [col] = query.result_columns
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

  let assert [col] = query.result_columns
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

  let assert [col] = query.result_columns
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

  let assert [col] = query.result_columns
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

  let assert [col] = query.result_columns
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
  let msg = query_analyzer.analysis_error_to_string(error)
  string.contains(msg, "unsupported expression") |> should.be_true()
  string.contains(msg, "BadQuery") |> should.be_true()
}
