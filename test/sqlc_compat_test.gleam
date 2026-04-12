import gleam/list
import gleeunit
import gleeunit/should
import simplifile
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer
import sqlode/query_parser
import sqlode/schema_parser

pub fn main() {
  gleeunit.main()
}

// ============================================================
// All SQL types: schema parsing and type inference
// ============================================================

pub fn all_types_schema_parsing_test() {
  let catalog = load_catalog("test/fixtures/all_types_schema.sql")
  let assert [table] = catalog.tables
  table.name |> should.equal("all_types")

  let assert [
    id,
    col_int,
    col_smallint,
    col_bigint,
    col_serial,
    col_float,
    col_double,
    col_real,
    col_numeric,
    col_decimal,
    col_bool,
    col_text,
    col_varchar,
    col_char,
    col_bytea,
    col_timestamp,
    col_datetime,
    col_date,
    col_time,
    col_timetz,
    col_uuid,
    col_json,
    col_jsonb,
  ] = table.columns

  // Integer types
  id.scalar_type |> should.equal(model.IntType)
  col_int.scalar_type |> should.equal(model.IntType)
  col_smallint.scalar_type |> should.equal(model.IntType)
  col_bigint.scalar_type |> should.equal(model.IntType)
  col_serial.scalar_type |> should.equal(model.IntType)

  // Float types
  col_float.scalar_type |> should.equal(model.FloatType)
  col_double.scalar_type |> should.equal(model.FloatType)
  col_real.scalar_type |> should.equal(model.FloatType)
  col_numeric.scalar_type |> should.equal(model.FloatType)
  col_decimal.scalar_type |> should.equal(model.FloatType)

  // Bool
  col_bool.scalar_type |> should.equal(model.BoolType)

  // String types
  col_text.scalar_type |> should.equal(model.StringType)
  col_varchar.scalar_type |> should.equal(model.StringType)
  col_char.scalar_type |> should.equal(model.StringType)

  // Bytes
  col_bytea.scalar_type |> should.equal(model.BytesType)

  // Date/time types
  col_timestamp.scalar_type |> should.equal(model.DateTimeType)
  col_datetime.scalar_type |> should.equal(model.DateTimeType)
  col_date.scalar_type |> should.equal(model.DateType)
  col_time.scalar_type |> should.equal(model.TimeType)
  col_timetz.scalar_type |> should.equal(model.TimeType)

  // UUID
  col_uuid.scalar_type |> should.equal(model.UuidType)

  // JSON types
  col_json.scalar_type |> should.equal(model.JsonType)
  col_jsonb.scalar_type |> should.equal(model.JsonType)
}

pub fn all_types_nullable_detection_test() {
  let catalog = load_catalog("test/fixtures/all_types_schema.sql")
  let assert [table] = catalog.tables

  let nullable_cols =
    table.columns
    |> list.filter(fn(col) { col.nullable })
    |> list.map(fn(col) { col.name })

  nullable_cols
  |> should.equal(["col_datetime", "col_timetz", "col_json", "col_jsonb"])
}

pub fn all_types_result_columns_star_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/all_types_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/all_types_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let analyzed =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert [get_all, list_all, _insert] = analyzed

  // :one with SELECT * should return all columns
  list.length(get_all.result_columns) |> should.equal(23)
  let assert [id_col, ..] = get_all.result_columns
  id_col.name |> should.equal("id")
  id_col.scalar_type |> should.equal(model.IntType)

  // :many with SELECT * should also return all columns
  list.length(list_all.result_columns) |> should.equal(23)
}

pub fn all_types_insert_params_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/all_types_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/all_types_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let analyzed =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert [_get, _list, insert] = analyzed
  // INSERT has 21 placeholders ($1..$21)
  insert.base.param_count |> should.equal(21)
}

// ============================================================
// Complex schema: multiple tables, foreign keys, constraints
// ============================================================

pub fn complex_schema_multiple_tables_test() {
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  list.length(catalog.tables) |> should.equal(6)

  let table_names = list.map(catalog.tables, fn(t) { t.name })
  list.contains(table_names, "categories") |> should.be_true()
  list.contains(table_names, "users") |> should.be_true()
  list.contains(table_names, "posts") |> should.be_true()
  list.contains(table_names, "comments") |> should.be_true()
  list.contains(table_names, "tags") |> should.be_true()
  list.contains(table_names, "post_tags") |> should.be_true()
}

pub fn complex_schema_column_types_test() {
  let catalog = load_catalog("test/fixtures/complex_schema.sql")

  let assert Ok(users) = list.find(catalog.tables, fn(t) { t.name == "users" })
  let assert [id, username, email, is_active, created_at, profile_image] =
    users.columns

  id.scalar_type |> should.equal(model.IntType)
  username.scalar_type |> should.equal(model.StringType)
  email.scalar_type |> should.equal(model.StringType)
  is_active.scalar_type |> should.equal(model.BoolType)
  created_at.scalar_type |> should.equal(model.DateTimeType)
  profile_image.scalar_type |> should.equal(model.BytesType)
  profile_image.nullable |> should.equal(True)
}

pub fn complex_schema_nullable_foreign_keys_test() {
  let catalog = load_catalog("test/fixtures/complex_schema.sql")

  let assert Ok(posts) = list.find(catalog.tables, fn(t) { t.name == "posts" })
  let assert Ok(category_id) =
    list.find(posts.columns, fn(c) { c.name == "category_id" })
  // category_id is nullable (no NOT NULL)
  category_id.nullable |> should.equal(True)

  let assert Ok(author_id) =
    list.find(posts.columns, fn(c) { c.name == "author_id" })
  // author_id is NOT NULL
  author_id.nullable |> should.equal(False)
}

// ============================================================
// Complex queries: JOINs, RETURNING, UPDATE, DELETE
// ============================================================

pub fn complex_query_basic_crud_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/complex_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let analyzed =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  // GetPost :one - should have result columns
  let assert Ok(get_post) =
    list.find(analyzed, fn(q) { q.base.name == "GetPost" })
  get_post.base.command |> should.equal(model.One)
  list.length(get_post.result_columns) |> should.equal(4)
  let assert [id, title, body, published] = get_post.result_columns
  id.scalar_type |> should.equal(model.IntType)
  title.scalar_type |> should.equal(model.StringType)
  body.scalar_type |> should.equal(model.StringType)
  published.scalar_type |> should.equal(model.BoolType)

  // CreatePost :exec - no result columns
  let assert Ok(create_post) =
    list.find(analyzed, fn(q) { q.base.name == "CreatePost" })
  create_post.base.command |> should.equal(model.Exec)
  create_post.result_columns |> should.equal([])
  create_post.base.param_count |> should.equal(8)

  // DeletePost :exec
  let assert Ok(delete_post) =
    list.find(analyzed, fn(q) { q.base.name == "DeletePost" })
  delete_post.base.command |> should.equal(model.Exec)
  delete_post.base.param_count |> should.equal(1)
}

pub fn complex_query_single_join_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/complex_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let analyzed =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(post_with_author) =
    list.find(analyzed, fn(q) { q.base.name == "GetPostWithAuthor" })
  list.length(post_with_author.result_columns) |> should.equal(2)

  let assert [title, username] = post_with_author.result_columns
  title.name |> should.equal("title")
  title.scalar_type |> should.equal(model.StringType)
  username.name |> should.equal("username")
  username.scalar_type |> should.equal(model.StringType)
}

pub fn complex_query_multi_join_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/complex_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let analyzed =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(post_full) =
    list.find(analyzed, fn(q) { q.base.name == "GetPostWithAuthorAndCategory" })
  list.length(post_full.result_columns) |> should.equal(3)

  let assert [title, username, cat_name] = post_full.result_columns
  title.name |> should.equal("title")
  username.name |> should.equal("username")
  cat_name.name |> should.equal("name")
}

pub fn complex_query_returning_clause_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/complex_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let analyzed =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  // INSERT ... RETURNING
  let assert Ok(create_returning) =
    list.find(analyzed, fn(q) { q.base.name == "CreatePostReturning" })
  create_returning.base.command |> should.equal(model.One)
  list.length(create_returning.result_columns) |> should.equal(2)
  let assert [id, title] = create_returning.result_columns
  id.name |> should.equal("id")
  id.scalar_type |> should.equal(model.IntType)
  title.name |> should.equal("title")

  // DELETE ... RETURNING
  let assert Ok(delete_returning) =
    list.find(analyzed, fn(q) { q.base.name == "DeletePostReturning" })
  delete_returning.base.command |> should.equal(model.One)
  list.length(delete_returning.result_columns) |> should.equal(2)

  // UPDATE ... RETURNING
  let assert Ok(update_returning) =
    list.find(analyzed, fn(q) { q.base.name == "UpdatePostReturning" })
  update_returning.base.command |> should.equal(model.One)
  list.length(update_returning.result_columns) |> should.equal(3)
  let assert [_, _, published] = update_returning.result_columns
  published.name |> should.equal("published")
  published.scalar_type |> should.equal(model.BoolType)
}

pub fn complex_query_update_params_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/complex_schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/complex_query.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let analyzed =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(update) =
    list.find(analyzed, fn(q) { q.base.name == "UpdatePostTitle" })
  update.base.param_count |> should.equal(2)
  list.length(update.params) |> should.equal(2)
}

// ============================================================
// sqlc macro edge cases
// ============================================================

pub fn macro_duplicate_arg_name_test() {
  let naming_ctx = naming.new()
  let queries =
    parse_queries(
      "test/fixtures/macro_edge_cases.sql",
      model.PostgreSQL,
      naming_ctx,
    )

  let assert Ok(search) =
    list.find(queries, fn(q) { q.name == "SearchByNameOrBio" })
  // Two sqlc.arg(search_term) should produce two separate placeholders
  search.param_count |> should.equal(2)
  list.length(search.macros) |> should.equal(2)
}

pub fn macro_mixed_arg_narg_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/macro_edge_cases.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let analyzed =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(insert) =
    list.find(analyzed, fn(q) { q.base.name == "InsertWithMixedMacros" })
  let assert [name_param, bio_param] = insert.params
  name_param.field_name |> should.equal("author_name")
  name_param.nullable |> should.equal(False)
  bio_param.field_name |> should.equal("author_bio")
  bio_param.nullable |> should.equal(True)
}

pub fn macro_slice_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/macro_edge_cases.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let analyzed =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(get_by_ids) =
    list.find(analyzed, fn(q) { q.base.name == "GetByMultipleIds" })
  let assert [param] = get_by_ids.params
  param.field_name |> should.equal("ids")
  param.is_list |> should.equal(True)
}

pub fn macro_update_with_multiple_macros_test() {
  let naming_ctx = naming.new()
  let catalog = load_catalog("test/fixtures/schema.sql")
  let queries =
    parse_queries(
      "test/fixtures/macro_edge_cases.sql",
      model.PostgreSQL,
      naming_ctx,
    )
  let analyzed =
    query_analyzer.analyze_queries(
      model.PostgreSQL,
      catalog,
      naming_ctx,
      queries,
    )

  let assert Ok(update) =
    list.find(analyzed, fn(q) { q.base.name == "UpdateWithNarg" })
  list.length(update.params) |> should.equal(3)

  let assert [name_param, bio_param, id_param] = update.params
  name_param.field_name |> should.equal("new_name")
  name_param.nullable |> should.equal(False)
  bio_param.field_name |> should.equal("new_bio")
  bio_param.nullable |> should.equal(True)
  id_param.field_name |> should.equal("author_id")
  id_param.nullable |> should.equal(False)
}

// ============================================================
// Helpers
// ============================================================

fn load_catalog(path: String) -> model.Catalog {
  let assert Ok(content) = simplifile.read(path)
  let assert Ok(catalog) = schema_parser.parse_files([#(path, content)])
  catalog
}

fn parse_queries(
  path: String,
  engine: model.Engine,
  naming_ctx: naming.NamingContext,
) -> List(model.ParsedQuery) {
  let assert Ok(content) = simplifile.read(path)
  let assert Ok(queries) =
    query_parser.parse_file(path, engine, naming_ctx, content)
  queries
}
