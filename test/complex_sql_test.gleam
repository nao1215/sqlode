//// Tests for the four complex SQL fixtures added for Issue #393.
//// These fixtures exercise the expression-aware IR on constructs
//// that were previously handled by token-rescan heuristics: CTEs
//// (including nested CTE references), window expressions, LATERAL
//// subqueries, correlated EXISTS, nested CASE with nullable
//// branches, and INSERT..SELECT..RETURNING with a CTE input.
////
//// Each fixture is checked at two layers:
////
//// 1. **Analyzer** — the `query_analyzer` pipeline must accept the
////    statement, infer the expected parameter types and produce the
////    documented result-column shape. The fixtures stress arithmetic
////    with casts, function-return inference, CASE branch unification
////    and LATERAL alias propagation.
////
//// 2. **Codegen** — the `codegen/queries`, `codegen/params` and
////    `codegen/models` modules must successfully render Gleam code
////    for the analyzed queries, and the generated output must
////    reference the expected top-level artefacts (param type name,
////    function name, command kind). This guards against the scenario
////    where analysis succeeds but codegen later drops columns or
////    emits placeholder output.

import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlode/codegen/params
import sqlode/codegen/queries
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer
import sqlode/query_parser
import sqlode/runtime
import sqlode/schema_parser

pub fn main() {
  gleeunit.main()
}

const schema_path = "test/fixtures/complex_sql_schema.sql"

fn catalog() -> model.Catalog {
  let assert Ok(content) = simplifile.read(schema_path)
  let assert Ok(#(cat, _)) =
    schema_parser.parse_files([#(schema_path, content)])
  cat
}

fn analyze(path: String) -> List(model.AnalyzedQuery) {
  let naming_ctx = naming.new()
  let cat = catalog()
  let assert Ok(content) = simplifile.read(path)
  let assert Ok(parsed) =
    query_parser.parse_file(path, model.PostgreSQL, naming_ctx, content)
  let assert Ok(analyzed) =
    query_analyzer.analyze_queries(model.PostgreSQL, cat, naming_ctx, parsed)
  analyzed
}

fn test_block(queries_path: String) -> model.SqlBlock {
  model.SqlBlock(
    name: None,
    engine: model.PostgreSQL,
    schema: [schema_path],
    queries: [queries_path],
    gleam: model.GleamOutput(
      out: "src/db",
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
    ),
    overrides: model.empty_overrides(),
  )
}

fn param_types(
  p: List(model.QueryParam),
) -> List(#(Int, model.ScalarType, Bool, Bool)) {
  list.map(p, fn(q) { #(q.index, q.scalar_type, q.nullable, q.is_list) })
}

fn result_columns(
  cols: List(model.ResultItem),
) -> List(#(String, model.ScalarType, Bool)) {
  list.filter_map(cols, fn(item) {
    case item {
      model.ScalarResult(rc) -> Ok(#(rc.name, rc.scalar_type, rc.nullable))
      model.EmbeddedResult(_) -> Error(Nil)
    }
  })
}

// ============================================================
// Fixture 1 — CTE + window + CASE + arithmetic
// ============================================================

pub fn cte_window_case_analyzer_test() {
  let analyzed = analyze("test/fixtures/complex_sql_cte_window_case.sql")
  let assert [query] = analyzed

  query.base.name |> should.equal("ListRankedUsers")
  query.base.command |> should.equal(runtime.QueryMany)

  // $1 is a cast timestamp (used in `p.created_at >= $1::timestamp`).
  // $2 is the cast int inside the scored_users arithmetic.
  // $3 is the outer WHERE filter against the CTE-derived `score`,
  // which is itself nullable (arithmetic with a casted parameter),
  // so the inferred parameter type inherits the column's nullability.
  param_types(query.params)
  |> should.equal([
    #(1, model.DateTimeType, False, False),
    #(2, model.IntType, False, False),
    #(3, model.IntType, True, False),
  ])

  // Result columns come from the outer SELECT over `scored_users`.
  // `id`/`email` flow through the CTE unchanged from `users`; `tier`
  // is the unified CASE result (all string literal branches); `score`
  // is the integer arithmetic. `score` is nullable because it mixes
  // a non-null aggregate with a casted parameter, and sqlode treats
  // casts as nullable in expression context so the caller is free to
  // pass a nullable parameter behind the cast.
  result_columns(query.result_columns)
  |> should.equal([
    #("id", model.IntType, False),
    #("email", model.StringType, False),
    #("tier", model.StringType, False),
    #("score", model.IntType, True),
  ])
}

pub fn cte_window_case_codegen_test() {
  let naming_ctx = naming.new()
  let block = test_block("test/fixtures/complex_sql_cte_window_case.sql")
  let analyzed = analyze("test/fixtures/complex_sql_cte_window_case.sql")

  let rendered_queries =
    queries.render(naming_ctx, block, analyzed, dict.new(), False)
  string.contains(rendered_queries, "pub fn list_ranked_users(")
  |> should.be_true()
  string.contains(rendered_queries, "command: runtime.QueryMany")
  |> should.be_true()

  let rendered_params =
    params.render(
      naming_ctx,
      analyzed,
      model.StringMapping,
      "db",
      "sqlode/runtime",
    )
  string.contains(rendered_params, "pub type ListRankedUsersParams {")
  |> should.be_true()
}

// ============================================================
// Fixture 2 — LATERAL subquery + aggregate projection
// ============================================================

pub fn lateral_aggregate_analyzer_test() {
  let analyzed = analyze("test/fixtures/complex_sql_lateral_aggregate.sql")
  let assert [query] = analyzed

  query.base.name |> should.equal("ListTeamsWithLatestPost")
  query.base.command |> should.equal(runtime.QueryMany)

  // The query uses a single sqlode.slice(team_ids) param against
  // `t.id`. The slice macro keeps the parameter's list-ness at `True`.
  let assert [single_param] = query.params
  single_param.index |> should.equal(1)
  single_param.scalar_type |> should.equal(model.IntType)
  single_param.is_list |> should.equal(True)

  // LATERAL alias `latest_post` projects `created_at` from posts
  // (timestamp). COALESCE's default makes `member_count` non-nullable.
  result_columns(query.result_columns)
  |> should.equal([
    #("id", model.IntType, False),
    #("name", model.StringType, False),
    #("latest_post_at", model.DateTimeType, True),
    #("member_count", model.IntType, False),
  ])
}

pub fn lateral_aggregate_codegen_test() {
  let naming_ctx = naming.new()
  let block = test_block("test/fixtures/complex_sql_lateral_aggregate.sql")
  let analyzed = analyze("test/fixtures/complex_sql_lateral_aggregate.sql")

  let rendered_queries =
    queries.render(naming_ctx, block, analyzed, dict.new(), False)
  string.contains(rendered_queries, "pub fn list_teams_with_latest_post(")
  |> should.be_true()
}

// ============================================================
// Fixture 3 — correlated EXISTS + nested CASE + nullable branches
// ============================================================

pub fn exists_case_analyzer_test() {
  let analyzed = analyze("test/fixtures/complex_sql_exists_case.sql")
  let assert [query] = analyzed

  query.base.name |> should.equal("ListReviewablePosts")
  query.base.command |> should.equal(runtime.QueryMany)

  // $1 and $2 are int casts inside `(p.score + $1::int) > $2::int`.
  param_types(query.params)
  |> should.equal([
    #(1, model.IntType, False, False),
    #(2, model.IntType, False, False),
  ])

  // `moderation_state` is a CASE with a string ELSE, so not nullable.
  // `review_timestamp` branches are `reviewed_at` (nullable) and NULL,
  // so the unified type is DateTime with nullable=True.
  result_columns(query.result_columns)
  |> should.equal([
    #("id", model.IntType, False),
    #("moderation_state", model.StringType, False),
    #("review_timestamp", model.DateTimeType, True),
  ])
}

pub fn exists_case_codegen_test() {
  let naming_ctx = naming.new()
  let block = test_block("test/fixtures/complex_sql_exists_case.sql")
  let analyzed = analyze("test/fixtures/complex_sql_exists_case.sql")

  let rendered_queries =
    queries.render(naming_ctx, block, analyzed, dict.new(), False)
  string.contains(rendered_queries, "pub fn list_reviewable_posts(")
  |> should.be_true()
}

// ============================================================
// Fixture 4 — INSERT .. SELECT with CTE + RETURNING
// ============================================================

pub fn insert_select_analyzer_test() {
  let analyzed = analyze("test/fixtures/complex_sql_insert_select.sql")
  let assert [query] = analyzed

  query.base.name |> should.equal("CreateAuditRows")
  query.base.command |> should.equal(runtime.QueryMany)

  // Only one placeholder ($1) — the updated_at cutoff inside the CTE.
  param_types(query.params)
  |> should.equal([#(1, model.DateTimeType, False, False)])

  // RETURNING columns map back to audit_log (the INSERT target).
  result_columns(query.result_columns)
  |> should.equal([
    #("id", model.IntType, False),
    #("post_id", model.IntType, False),
    #("actor_id", model.IntType, False),
    #("action", model.StringType, False),
  ])
}

pub fn insert_select_codegen_test() {
  let naming_ctx = naming.new()
  let block = test_block("test/fixtures/complex_sql_insert_select.sql")
  let analyzed = analyze("test/fixtures/complex_sql_insert_select.sql")

  let rendered_queries =
    queries.render(naming_ctx, block, analyzed, dict.new(), False)
  string.contains(rendered_queries, "pub fn create_audit_rows(")
  |> should.be_true()
}
