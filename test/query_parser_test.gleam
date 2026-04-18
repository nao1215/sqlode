import gleam/list
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlode/model
import sqlode/naming
import sqlode/query_parser
import sqlode/runtime

pub fn main() {
  gleeunit.main()
}

/// Thin wrapper that unwraps `query_ir.TokenizedQuery` to `model.ParsedQuery`
/// so the parser-focused assertions in this file can keep accessing
/// `.name`, `.sql`, `.macros` etc. directly. The analyzer pipeline still
/// sees the tokenized form.
fn parse_file(
  path: String,
  engine: model.Engine,
  naming_ctx: naming.NamingContext,
  content: String,
) -> Result(List(model.ParsedQuery), query_parser.ParseError) {
  query_parser.parse_file(path, engine, naming_ctx, content)
  |> result.map(list.map(_, fn(q) { q.base }))
}

pub fn parse_queries_from_sqlc_annotations_test() {
  let naming_ctx = naming.new()
  let assert Ok(content) = simplifile.read("test/fixtures/query.sql")
  let assert Ok(queries) =
    parse_file("test/fixtures/query.sql", model.PostgreSQL, naming_ctx, content)

  list.length(queries) |> should.equal(2)

  let assert [get_author, list_authors] = queries
  get_author.name |> should.equal("GetAuthor")
  get_author.function_name |> should.equal("get_author")
  get_author.command |> should.equal(runtime.QueryOne)
  get_author.param_count |> should.equal(1)
  get_author.macros |> should.equal([])
  list_authors.function_name |> should.equal("list_authors")
  list_authors.command |> should.equal(runtime.QueryMany)
}

pub fn reject_query_without_sql_body_test() {
  let naming_ctx = naming.new()
  let content = "-- name: GetAuthor :one\n"

  let assert Error(error) =
    parse_file("broken.sql", model.PostgreSQL, naming_ctx, content)

  query_parser.error_to_string(error)
  |> should.equal("broken.sql:1: query GetAuthor is missing SQL body")
}

pub fn count_mysql_placeholders_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: CreateAuthor :exec\n"
    <> "INSERT INTO authors (name, bio) VALUES (?, ?);"

  let assert Ok(queries) =
    parse_file("mysql.sql", model.MySQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
}

pub fn count_sqlite_named_placeholders_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetAuthor :one\n"
    <> "SELECT id FROM authors WHERE id = :id OR name = @name OR slug = $slug OR code = ?2;"

  let assert Ok(queries) =
    parse_file("sqlite.sql", model.SQLite, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(4)
}

pub fn expand_sqlc_arg_macro_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetByName :one\n"
    <> "SELECT id FROM authors WHERE name = sqlode.arg(author_name);"

  let assert Ok(queries) =
    parse_file("arg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  query.macros
  |> should.equal([model.MacroArg(index: 1, name: "author_name")])
  string.contains(query.sql, "sqlode.arg") |> should.be_false()
  string.contains(query.sql, "__sqlode_param_1__") |> should.be_true()
}

pub fn expand_sqlc_narg_macro_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: UpdateBio :exec\n"
    <> "UPDATE authors SET bio = sqlode.narg(new_bio) WHERE id = sqlode.arg(author_id);"

  let assert Ok(queries) =
    parse_file("narg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
  query.macros
  |> should.equal([
    model.MacroNarg(index: 1, name: "new_bio"),
    model.MacroArg(index: 2, name: "author_id"),
  ])
  string.contains(query.sql, "sqlode.narg") |> should.be_false()
  string.contains(query.sql, "sqlode.arg") |> should.be_false()
}

pub fn expand_sqlc_arg_mysql_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetByName :one\n"
    <> "SELECT id FROM authors WHERE name = sqlode.arg(author_name);"

  let assert Ok(queries) =
    parse_file("arg_mysql.sql", model.MySQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  string.contains(query.sql, "__sqlode_param_1__") |> should.be_true()
}

// Quoted macro name tests

pub fn expand_sqlc_arg_single_quoted_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetByName :one\n"
    <> "SELECT id FROM authors WHERE name = sqlode.arg('author_name');"

  let assert Ok(queries) =
    parse_file("arg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  query.macros
  |> should.equal([model.MacroArg(index: 1, name: "author_name")])
  string.contains(query.sql, "sqlode.arg") |> should.be_false()
  string.contains(query.sql, "__sqlode_param_1__") |> should.be_true()
}

pub fn expand_sqlc_arg_double_quoted_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetByName :one\n"
    <> "SELECT id FROM authors WHERE name = sqlode.arg(\"author_name\");"

  let assert Ok(queries) =
    parse_file("arg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  query.macros
  |> should.equal([model.MacroArg(index: 1, name: "author_name")])
}

pub fn expand_sqlc_narg_single_quoted_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: UpdateBio :exec\n"
    <> "UPDATE authors SET bio = sqlode.narg('new_bio') WHERE id = sqlode.arg(author_id);"

  let assert Ok(queries) =
    parse_file("narg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
  query.macros
  |> should.equal([
    model.MacroNarg(index: 1, name: "new_bio"),
    model.MacroArg(index: 2, name: "author_id"),
  ])
}

pub fn expand_sqlc_slice_double_quoted_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetByIds :many\n"
    <> "SELECT id, name FROM authors WHERE id IN (sqlode.slice(\"ids\"));"

  let assert Ok(queries) =
    parse_file("slice.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.macros
  |> should.equal([model.MacroSlice(index: 1, name: "ids")])
}

// @name shorthand tests

pub fn expand_at_name_postgresql_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetByName :one\n"
    <> "SELECT id FROM authors WHERE name = @author_name;"

  let assert Ok(queries) =
    parse_file("at.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  query.macros
  |> should.equal([model.MacroArg(index: 1, name: "author_name")])
  string.contains(query.sql, "@author_name") |> should.be_false()
  string.contains(query.sql, "__sqlode_param_1__") |> should.be_true()
}

pub fn expand_at_name_sqlite_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetByName :one\n"
    <> "SELECT id FROM authors WHERE name = @author_name;"

  let assert Ok(queries) =
    parse_file("at.sql", model.SQLite, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  query.macros
  |> should.equal([model.MacroArg(index: 1, name: "author_name")])
  string.contains(query.sql, "@author_name") |> should.be_false()
  string.contains(query.sql, "__sqlode_param_1__") |> should.be_true()
}

pub fn expand_multiple_at_names_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: UpdateBio :exec\n"
    <> "UPDATE authors SET bio = @new_bio WHERE id = @author_id;"

  let assert Ok(queries) =
    parse_file("at.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
  query.macros
  |> should.equal([
    model.MacroArg(index: 1, name: "new_bio"),
    model.MacroArg(index: 2, name: "author_id"),
  ])
  string.contains(query.sql, "__sqlode_param_1__") |> should.be_true()
  string.contains(query.sql, "__sqlode_param_2__") |> should.be_true()
}

pub fn expand_at_name_mixed_with_sqlc_arg_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: Update :exec\n"
    <> "UPDATE authors SET bio = @new_bio WHERE id = sqlode.arg(author_id);"

  let assert Ok(queries) =
    parse_file("at.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
  query.macros
  |> should.equal([
    model.MacroArg(index: 1, name: "new_bio"),
    model.MacroArg(index: 2, name: "author_id"),
  ])
}

pub fn at_name_not_expanded_on_mysql_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetByName :one\n"
    <> "SELECT id FROM authors WHERE name = @author_name;"

  let assert Ok(queries) =
    parse_file("at.sql", model.MySQL, naming_ctx, content)
  let assert [query] = queries

  query.macros |> should.equal([])
  string.contains(query.sql, "@author_name") |> should.be_true()
}

// Error and boundary tests

pub fn invalid_annotation_format_test() {
  let naming_ctx = naming.new()
  let content = "-- name: OnlyName\nSELECT 1;"

  let assert Error(error) =
    parse_file("bad.sql", model.PostgreSQL, naming_ctx, content)
  let msg = query_parser.error_to_string(error)
  string.contains(msg, "expected") |> should.be_true()
  string.contains(msg, ":one") |> should.be_true()
  string.contains(msg, ":exec") |> should.be_true()
}

pub fn invalid_command_test() {
  let naming_ctx = naming.new()
  let content = "-- name: MyQuery :unknown\nSELECT 1;"

  let assert Error(error) =
    parse_file("bad.sql", model.PostgreSQL, naming_ctx, content)
  let msg = query_parser.error_to_string(error)
  string.contains(msg, "must be one of") |> should.be_true()
}

pub fn file_with_no_annotations_test() {
  let naming_ctx = naming.new()
  let content = "SELECT 1;\nSELECT 2;"

  let assert Ok(queries) =
    parse_file("none.sql", model.PostgreSQL, naming_ctx, content)
  queries |> should.equal([])
}

pub fn empty_file_test() {
  let naming_ctx = naming.new()
  let assert Ok(queries) =
    parse_file("empty.sql", model.PostgreSQL, naming_ctx, "")
  queries |> should.equal([])
}

pub fn multiple_queries_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: Q1 :one\nSELECT 1;\n"
    <> "-- name: Q2 :many\nSELECT 2;\n"
    <> "-- name: Q3 :exec\nINSERT INTO t VALUES (1);"

  let assert Ok(queries) =
    parse_file("multi.sql", model.PostgreSQL, naming_ctx, content)
  list.length(queries) |> should.equal(3)

  let assert [q1, q2, q3] = queries
  q1.name |> should.equal("Q1")
  q1.command |> should.equal(runtime.QueryOne)
  q2.name |> should.equal("Q2")
  q2.command |> should.equal(runtime.QueryMany)
  q3.name |> should.equal("Q3")
  q3.command |> should.equal(runtime.QueryExec)
}

pub fn all_command_types_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: A :one\nSELECT 1;\n"
    <> "-- name: B :many\nSELECT 1;\n"
    <> "-- name: C :exec\nSELECT 1;\n"
    <> "-- name: D :execresult\nSELECT 1;\n"
    <> "-- name: E :execrows\nSELECT 1;\n"
    <> "-- name: F :execlastid\nSELECT 1;"

  let assert Ok(queries) =
    parse_file("cmds.sql", model.PostgreSQL, naming_ctx, content)
  list.length(queries) |> should.equal(6)

  let assert [a, b, c, d, e, f] = queries
  a.command |> should.equal(runtime.QueryOne)
  b.command |> should.equal(runtime.QueryMany)
  c.command |> should.equal(runtime.QueryExec)
  d.command |> should.equal(runtime.QueryExecResult)
  e.command |> should.equal(runtime.QueryExecRows)
  f.command |> should.equal(runtime.QueryExecLastId)
}

pub fn multiline_sql_body_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetAuthor :one\n"
    <> "SELECT id,\n"
    <> "       name,\n"
    <> "       bio\n"
    <> "FROM authors\n"
    <> "WHERE id = $1;"

  let assert Ok(queries) =
    parse_file("multi.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.param_count |> should.equal(1)
  // Token-first rendering normalizes keywords to lowercase
  string.contains(query.sql, "select") |> should.be_true()
  string.contains(query.sql, "id") |> should.be_true()
}

// --- Placeholder inside string literal / comment tests (#118) ---

pub fn ignore_placeholder_in_single_quoted_string_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetAuthorWithLiteral :one\n"
    <> "SELECT id, name\n"
    <> "FROM authors\n"
    <> "WHERE note = '$2' OR id = $1;"

  let assert Ok(queries) =
    parse_file("lit.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  // $2 inside string should be ignored, only $1 counts
  query.param_count |> should.equal(1)
}

pub fn ignore_placeholder_in_line_comment_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetById :one\n"
    <> "SELECT id, name\n"
    <> "FROM authors\n"
    <> "WHERE id = $1; -- $2 is not used"

  let assert Ok(queries) =
    parse_file("cmt.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
}

pub fn ignore_placeholder_in_block_comment_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetById :one\n"
    <> "SELECT id, name\n"
    <> "FROM authors\n"
    <> "/* WHERE bio = $2 */\n"
    <> "WHERE id = $1;"

  let assert Ok(queries) =
    parse_file("cmt.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
}

pub fn ignore_at_name_in_string_literal_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetByNote :one\n"
    <> "SELECT id FROM authors\n"
    <> "WHERE note = '@skip_me' AND id = @real_id;"

  let assert Ok(queries) =
    parse_file("at.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  // @skip_me inside string should not be expanded
  query.param_count |> should.equal(1)
  query.macros |> should.equal([model.MacroArg(index: 1, name: "real_id")])
  string.contains(query.sql, "'@skip_me'") |> should.be_true()
}

pub fn ignore_question_mark_in_string_mysql_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: GetByNote :one\n"
    <> "SELECT id FROM authors\n"
    <> "WHERE note = 'is this a ?' AND id = ?;"

  let assert Ok(queries) = parse_file("q.sql", model.MySQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
}

pub fn sqlite_repeated_colon_placeholder_dedup_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: ReusedNamed :one\n"
    <> "SELECT id FROM authors WHERE id = :id OR parent_id = :id;"

  let assert Ok(queries) =
    parse_file("sqlite.sql", model.SQLite, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
}

pub fn sqlite_repeated_dollar_placeholder_dedup_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: ReusedDollar :one\n"
    <> "SELECT id FROM authors WHERE id = $id OR parent_id = $id;"

  let assert Ok(queries) =
    parse_file("sqlite.sql", model.SQLite, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
}

pub fn sqlite_repeated_at_placeholder_dedup_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: ReusedAt :one\n"
    <> "SELECT id FROM authors WHERE id = @id OR parent_id = @id;"

  let assert Ok(queries) =
    parse_file("sqlite.sql", model.SQLite, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
}

pub fn sqlite_distinct_named_placeholders_not_deduped_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: DistinctNames :one\n"
    <> "SELECT id FROM authors WHERE id = :id OR name = :name;"

  let assert Ok(queries) =
    parse_file("sqlite.sql", model.SQLite, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
}

pub fn sqlite_colon_and_at_are_different_params_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: DifferentPrefix :one\n"
    <> "SELECT id FROM authors WHERE id = :id OR parent_id = @id;"

  let assert Ok(queries) =
    parse_file("sqlite.sql", model.SQLite, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
}

pub fn sqlite_bare_question_marks_not_deduped_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: BareQuestions :exec\n"
    <> "INSERT INTO authors (name, bio) VALUES (?, ?);"

  let assert Ok(queries) =
    parse_file("sqlite.sql", model.SQLite, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
}

pub fn sqlite_repeated_numbered_placeholder_dedup_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: ReusedNumbered :one\n"
    <> "SELECT id FROM authors WHERE id = ?1 OR parent_id = ?1;"

  let assert Ok(queries) =
    parse_file("sqlite.sql", model.SQLite, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
}

pub fn postgresql_plain_dollar_quoted_string_masks_placeholder_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: DollarPlain :one\n"
    <> "SELECT $$literal $1 inside$$, id FROM authors WHERE id = $1;"

  let assert Ok(queries) =
    parse_file("pg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
}

pub fn postgresql_tagged_dollar_quoted_string_masks_placeholder_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: DollarTag :one\n"
    <> "SELECT $tag$literal $1 inside$tag$, id FROM authors WHERE id = $2;"

  let assert Ok(queries) =
    parse_file("pg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
}

pub fn postgresql_dollar_quoted_does_not_affect_real_params_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: DollarMixed :one\n"
    <> "SELECT $fn$body with $1 and $2$fn$, id FROM authors WHERE id = $1 AND name = $2;"

  let assert Ok(queries) =
    parse_file("pg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(2)
}

pub fn sqlite_dollar_not_treated_as_dollar_quoted_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: SqliteDollar :one\n" <> "SELECT id FROM authors WHERE id = $id;"

  let assert Ok(queries) =
    parse_file("sqlite.sql", model.SQLite, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
}

pub fn sqlc_arg_in_string_literal_ignored_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: MacroInString :one\n"
    <> "SELECT id FROM authors WHERE note = 'sqlode.arg(fake)' AND id = sqlode.arg(real_id);"

  let assert Ok(queries) =
    parse_file("pg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  query.macros
  |> should.equal([model.MacroArg(index: 1, name: "real_id")])
  string.contains(query.sql, "'sqlode.arg(fake)'") |> should.be_true()
}

pub fn sqlc_narg_in_line_comment_ignored_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: MacroInComment :one\n"
    <> "SELECT id FROM authors\n"
    <> "-- WHERE name = sqlode.narg(ignored)\n"
    <> "WHERE id = sqlode.arg(real_id);"

  let assert Ok(queries) =
    parse_file("pg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  query.macros
  |> should.equal([model.MacroArg(index: 1, name: "real_id")])
}

pub fn sqlc_slice_in_block_comment_ignored_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: MacroInBlock :many\n"
    <> "SELECT id FROM authors\n"
    <> "WHERE /* sqlode.slice(phantom) */ id IN (sqlode.slice(real_ids));"

  let assert Ok(queries) =
    parse_file("pg.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries

  query.param_count |> should.equal(1)
  query.macros
  |> should.equal([model.MacroSlice(index: 1, name: "real_ids")])
}

pub fn error_to_string_coverage_test() {
  query_parser.error_to_string(query_parser.InvalidAnnotation(
    path: "test.sql",
    line: 5,
    detail: "bad format",
  ))
  |> string.contains("test.sql:5")
  |> should.be_true()

  query_parser.error_to_string(query_parser.MissingSql(
    path: "test.sql",
    line: 3,
    name: "MyQuery",
  ))
  |> string.contains("MyQuery")
  |> should.be_true()
}

pub fn skip_annotation_skips_query_test() {
  let naming_ctx = naming.new()
  let content =
    "-- sqlode:skip\n"
    <> "-- name: SkippedQuery :one\n"
    <> "SELECT complex_stuff FROM somewhere;\n"
    <> "\n"
    <> "-- name: KeptQuery :many\n"
    <> "SELECT id FROM authors;\n"

  let assert Ok(queries) =
    parse_file("test.sql", model.PostgreSQL, naming_ctx, content)

  list.length(queries) |> should.equal(1)
  let assert [query] = queries
  query.name |> should.equal("KeptQuery")
  query.command |> should.equal(runtime.QueryMany)
}

pub fn skip_annotation_all_queries_skipped_test() {
  let naming_ctx = naming.new()
  let content =
    "-- sqlode:skip\n"
    <> "-- name: SkippedOne :one\n"
    <> "SELECT 1;\n"
    <> "\n"
    <> "-- sqlode:skip\n"
    <> "-- name: SkippedTwo :many\n"
    <> "SELECT 2;\n"

  let assert Ok(queries) =
    parse_file("test.sql", model.PostgreSQL, naming_ctx, content)

  list.length(queries) |> should.equal(0)
}

pub fn skip_annotation_middle_query_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: First :one\n"
    <> "SELECT 1;\n"
    <> "\n"
    <> "-- sqlode:skip\n"
    <> "-- name: Second :one\n"
    <> "SELECT 2;\n"
    <> "\n"
    <> "-- name: Third :many\n"
    <> "SELECT 3;\n"

  let assert Ok(queries) =
    parse_file("test.sql", model.PostgreSQL, naming_ctx, content)

  list.length(queries) |> should.equal(2)
  let names = list.map(queries, fn(q) { q.name })
  names |> should.equal(["First", "Third"])
}

// Block-comment annotation tests (sqlc-style `/* name: ... */`)

pub fn parse_block_annotation_one_test() {
  let naming_ctx = naming.new()
  let content =
    "/* name: GetAuthor :one */\nSELECT id FROM authors WHERE id = $1;"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.name |> should.equal("GetAuthor")
  query.function_name |> should.equal("get_author")
  query.command |> should.equal(runtime.QueryOne)
  query.param_count |> should.equal(1)
}

pub fn parse_block_annotation_many_test() {
  let naming_ctx = naming.new()
  let content = "/* name: ListAll :many */\nSELECT * FROM authors;"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.name |> should.equal("ListAll")
  query.command |> should.equal(runtime.QueryMany)
}

pub fn parse_block_annotation_exec_test() {
  let naming_ctx = naming.new()
  let content = "/* name: InsertRow :exec */\nINSERT INTO t (v) VALUES ($1);"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.name |> should.equal("InsertRow")
  query.command |> should.equal(runtime.QueryExec)
}

pub fn parse_block_annotation_whitespace_tolerance_test() {
  let naming_ctx = naming.new()
  let content = "/*    name:   Spaced   :one    */\nSELECT 1;"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.name |> should.equal("Spaced")
  query.command |> should.equal(runtime.QueryOne)
}

pub fn parse_block_annotation_no_inner_space_test() {
  let naming_ctx = naming.new()
  let content = "/*name: Tight :one*/\nSELECT 1;"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.name |> should.equal("Tight")
  query.command |> should.equal(runtime.QueryOne)
}

pub fn parse_mixed_line_and_block_annotations_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: First :one\n"
    <> "SELECT 1;\n"
    <> "\n"
    <> "/* name: Second :many */\n"
    <> "SELECT 2;\n"
    <> "\n"
    <> "-- name: Third :exec\n"
    <> "INSERT INTO t VALUES (1);\n"

  let assert Ok(queries) =
    parse_file("mixed.sql", model.PostgreSQL, naming_ctx, content)
  list.length(queries) |> should.equal(3)

  let assert [q1, q2, q3] = queries
  q1.name |> should.equal("First")
  q1.command |> should.equal(runtime.QueryOne)
  q2.name |> should.equal("Second")
  q2.command |> should.equal(runtime.QueryMany)
  q3.name |> should.equal("Third")
  q3.command |> should.equal(runtime.QueryExec)
}

pub fn parse_block_annotation_multiline_body_test() {
  let naming_ctx = naming.new()
  let content =
    "/* name: BigQuery :many */\n"
    <> "SELECT id,\n"
    <> "       name,\n"
    <> "       bio\n"
    <> "FROM authors\n"
    <> "WHERE id = $1;"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.name |> should.equal("BigQuery")
  query.param_count |> should.equal(1)
}

pub fn parse_block_annotation_with_macro_test() {
  let naming_ctx = naming.new()
  let content =
    "/* name: Search :many */\n"
    <> "SELECT id FROM authors WHERE name = sqlode.arg(author_name);"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.param_count |> should.equal(1)
  list.length(query.macros) |> should.equal(1)
}

pub fn parse_block_annotation_body_with_regular_block_comment_test() {
  let naming_ctx = naming.new()
  let content =
    "/* name: WithComment :one */\n"
    <> "SELECT id\n"
    <> "/* just a regular comment */\n"
    <> "FROM authors WHERE id = $1;"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.name |> should.equal("WithComment")
  query.param_count |> should.equal(1)
}

pub fn parse_block_comment_other_directive_ignored_test() {
  let naming_ctx = naming.new()
  let content =
    "-- name: Real :one\n" <> "/* other: bogus :many */\n" <> "SELECT 1;"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.name |> should.equal("Real")
  query.command |> should.equal(runtime.QueryOne)
}

pub fn parse_block_annotation_inline_sql_not_annotation_test() {
  let naming_ctx = naming.new()
  // Line does not end with */, so it's not a valid annotation line.
  let content = "/* name: X :one */ SELECT 1;"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  queries |> should.equal([])
}

pub fn parse_block_annotation_unclosed_ignored_test() {
  let naming_ctx = naming.new()
  let content = "/* name: NotReally :one\nSELECT 1;"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  queries |> should.equal([])
}

pub fn parse_block_annotation_multiline_not_annotation_test() {
  let naming_ctx = naming.new()
  // Annotation text split across lines is not supported.
  let content = "/* name: Split\n" <> " :one */\n" <> "SELECT 1;"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  queries |> should.equal([])
}

pub fn parse_block_annotation_invalid_command_test() {
  let naming_ctx = naming.new()
  let content = "/* name: Q :bogus */\nSELECT 1;"

  let assert Error(error) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let msg = query_parser.error_to_string(error)
  string.contains(msg, "must be one of") |> should.be_true()
}

pub fn parse_block_annotation_missing_command_test() {
  let naming_ctx = naming.new()
  let content = "/* name: OnlyName */\nSELECT 1;"

  let assert Error(error) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let msg = query_parser.error_to_string(error)
  string.contains(msg, "/* name:") |> should.be_true()
}

pub fn parse_block_annotation_missing_sql_body_test() {
  let naming_ctx = naming.new()
  let content = "/* name: NoBody :one */\n"

  let assert Error(error) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)

  query_parser.error_to_string(error)
  |> should.equal("block.sql:1: query NoBody is missing SQL body")
}

pub fn skip_annotation_applies_to_block_annotation_test() {
  let naming_ctx = naming.new()
  let content =
    "-- sqlode:skip\n"
    <> "/* name: Skipped :one */\n"
    <> "SELECT 1;\n"
    <> "\n"
    <> "-- name: Kept :many\n"
    <> "SELECT 2;\n"

  let assert Ok(queries) =
    parse_file("block.sql", model.PostgreSQL, naming_ctx, content)
  let assert [query] = queries
  query.name |> should.equal("Kept")
  query.command |> should.equal(runtime.QueryMany)
}
