//// Tests for the `sqlode verify` static verification lane
//// introduced for Issue #395.
////
//// Covers the three observable behaviours of the command:
////
//// 1. A healthy project produces a `Report` with no findings.
//// 2. A query with more parameters than `query_parameter_limit`
////    produces one finding that names the query and the limit.
//// 3. An analysis error (unknown table) is surfaced as a finding
////    instead of short-circuiting, so a CI gate can see every
////    problem in one run.

import gleam/list
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import sqlode/internal/model
import sqlode/internal/verify

pub fn main() {
  gleeunit.main()
}

fn make_block(
  schema_path: String,
  query_path: String,
  out: String,
  query_parameter_limit: option.Option(Int),
) -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: model.PostgreSQL,
    schema: [schema_path],
    queries: [query_path],
    gleam: model.GleamOutput(
      out: out,
      runtime: model.Raw,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
      query_parameter_limit: query_parameter_limit,
    ),
    overrides: model.empty_overrides(),
  )
}

pub fn verify_healthy_project_produces_no_findings_test() {
  let cfg =
    model.Config(version: 2, sql: [
      make_block(
        "test/fixtures/verify_ok_schema.sql",
        "test/fixtures/verify_ok_query.sql",
        "src/verify_ok_out",
        option.None,
      ),
    ])
  let report = verify.verify_config(cfg)
  report.findings |> should.equal([])
}

pub fn verify_rejects_query_over_parameter_limit_test() {
  // FilterAuthors has three inferred parameters ($1, $2, $3).
  // Setting query_parameter_limit: 2 must produce exactly one
  // finding naming the query, the inferred count, and the limit.
  let cfg =
    model.Config(version: 2, sql: [
      make_block(
        "test/fixtures/verify_ok_schema.sql",
        "test/fixtures/verify_over_limit_query.sql",
        "src/verify_limit_out",
        option.Some(2),
      ),
    ])
  let report = verify.verify_config(cfg)
  let assert [finding] = report.findings
  finding.block_out |> should.equal("src/verify_limit_out")
  string.contains(finding.detail, "FilterAuthors") |> should.be_true()
  string.contains(finding.detail, "query_parameter_limit 2") |> should.be_true()
  string.contains(finding.detail, "3 inferred parameter") |> should.be_true()
}

pub fn verify_parameter_limit_none_allows_any_count_test() {
  // Without the limit set, the same three-parameter query must
  // pass verification cleanly.
  let cfg =
    model.Config(version: 2, sql: [
      make_block(
        "test/fixtures/verify_ok_schema.sql",
        "test/fixtures/verify_over_limit_query.sql",
        "src/verify_nolimit_out",
        option.None,
      ),
    ])
  let report = verify.verify_config(cfg)
  report.findings |> should.equal([])
}

pub fn verify_surfaces_analysis_error_as_finding_test() {
  // Use a schema that does not define the table the queries
  // reference. `generate` would stop on the analysis error; verify
  // must carry it through as a finding so CI sees the diagnostic
  // instead of a traceback.
  let cfg =
    model.Config(version: 2, sql: [
      make_block(
        "test/fixtures/ambiguous_param_schema.sql",
        "test/fixtures/verify_ok_query.sql",
        "src/verify_unknown_out",
        option.None,
      ),
    ])
  let report = verify.verify_config(cfg)
  list.length(report.findings) |> should.equal(1)
  let assert [finding] = report.findings
  // The verify_ok_query references the `authors` table, which the
  // ambiguous_param schema does not define. Any finding mentioning
  // `authors` proves the analyser error propagated through.
  // The finding must name one of the queries from the input file
  // so operators can locate the offending query in the source. The
  // exact error shape depends on which analysis step tripped first
  // (table-not-found vs. parameter inference failure), and both are
  // acceptable reports for this mismatched schema/query pair.
  string.contains(finding.detail, "GetAuthor") |> should.be_true()
}

pub fn report_to_string_joins_findings_with_block_tag_test() {
  // The report renderer must prefix every finding with the block
  // out directory so multi-block reports stay attributable.
  let report =
    verify.Report(findings: [
      verify.Finding(block_out: "src/one", detail: "a"),
      verify.Finding(block_out: "src/two", detail: "b"),
    ])
  let rendered = verify.report_to_string(report)
  string.contains(rendered, "[src/one] a") |> should.be_true()
  string.contains(rendered, "[src/two] b") |> should.be_true()
}

pub fn report_to_string_reports_all_clear_on_empty_findings_test() {
  let report = verify.Report(findings: [])
  verify.report_to_string(report) |> should.equal("All checks passed.")
}

pub fn verify_accepts_schema_and_queries_directories_test() {
  // A directory-style config must verify cleanly the same way
  // `generate` accepts it. Before Issue #440, verify tried to
  // simplifile.read(dir) and reported an "Is a directory" OS
  // error as a finding, which made the command unusable for
  // every directory-based config.
  let cfg =
    model.Config(version: 2, sql: [
      make_block(
        "test/fixtures/schema_dir",
        "test/fixtures/query_dir",
        "src/verify_dir_out",
        option.None,
      ),
    ])
  let report = verify.verify_config(cfg)
  report.findings |> should.equal([])
}

pub fn verify_surfaces_empty_schema_directory_as_finding_test() {
  // Empty directories must produce the same user-facing error
  // text generate reports ("no .sql files"), so a CI gate that
  // runs verify before generate catches the same class of
  // misconfiguration.
  let cfg =
    model.Config(version: 2, sql: [
      make_block(
        "test/fixtures/empty_dir",
        "test/fixtures/verify_ok_query.sql",
        "src/verify_empty_schema_out",
        option.None,
      ),
    ])
  let report = verify.verify_config(cfg)
  let assert [finding] = report.findings
  string.contains(finding.detail, "no .sql files") |> should.be_true()
}

pub fn verify_surfaces_empty_query_directory_as_finding_test() {
  let cfg =
    model.Config(version: 2, sql: [
      make_block(
        "test/fixtures/verify_ok_schema.sql",
        "test/fixtures/empty_dir",
        "src/verify_empty_query_out",
        option.None,
      ),
    ])
  let report = verify.verify_config(cfg)
  let assert [finding] = report.findings
  string.contains(finding.detail, "no .sql files") |> should.be_true()
}

// ============================================================
// Generate-parity validation tests (Issue #441)
//
// `verify` is meant to be a trustworthy pre-generation CI gate:
// anything `generate` would reject must also be reported by
// `verify`. Each test below locks in one of the four shared
// post-parse checks.
// ============================================================

fn make_block_with(
  schema_path: String,
  query_path: String,
  out: String,
  engine: model.Engine,
  runtime: model.Runtime,
) -> model.SqlBlock {
  model.SqlBlock(
    name: option.None,
    engine: engine,
    schema: [schema_path],
    queries: [query_path],
    gleam: model.GleamOutput(
      out: out,
      runtime: runtime,
      type_mapping: model.StringMapping,
      emit_sql_as_comment: False,
      emit_exact_table_names: False,
      omit_unused_models: False,
      vendor_runtime: False,
      strict_views: False,
      query_parameter_limit: option.None,
    ),
    overrides: model.empty_overrides(),
  )
}

pub fn verify_rejects_duplicate_query_names_test() {
  // duplicate_query.sql declares `GetAuthor` twice. `generate`
  // rejects this immediately; `verify` used to print "All checks
  // passed" for the same config. Both commands must now reject
  // it with the same diagnostic.
  let cfg =
    model.Config(version: 2, sql: [
      make_block(
        "test/fixtures/verify_ok_schema.sql",
        "test/fixtures/duplicate_query.sql",
        "src/verify_dupe_out",
        option.None,
      ),
    ])
  let report = verify.verify_config(cfg)
  let assert [finding] = report.findings
  string.contains(finding.detail, "duplicate query name") |> should.be_true()
  string.contains(finding.detail, "GetAuthor") |> should.be_true()
}

pub fn verify_rejects_normalized_name_collision_test() {
  // Different annotation names that normalize to the same
  // snake_case `function_name` would produce duplicate Gleam
  // declarations. `generate` (and therefore `verify`) must
  // reject the config before it can reach the codegen stage.
  let cfg =
    model.Config(version: 2, sql: [
      make_block(
        "test/fixtures/verify_ok_schema.sql",
        "test/fixtures/normalized_collision_query.sql",
        "src/verify_normalized_out",
        option.None,
      ),
    ])
  let report = verify.verify_config(cfg)
  let assert [finding] = report.findings
  string.contains(finding.detail, "normalize to the generated identifier")
  |> should.be_true()
  string.contains(finding.detail, "get_user") |> should.be_true()
  string.contains(finding.detail, "GetUser") |> should.be_true()
}

pub fn verify_rejects_unsupported_batch_annotation_test() {
  // :batchmany is not supported by any codegen path. `generate`
  // rejects it; `verify` must surface the same finding so CI
  // catches the gap before generation.
  let cfg =
    model.Config(version: 2, sql: [
      make_block_with(
        "test/fixtures/all_commands_schema.sql",
        "test/fixtures/batchmany_query.sql",
        "src/verify_batch_out",
        model.SQLite,
        model.Raw,
      ),
    ])
  let report = verify.verify_config(cfg)
  let assert [finding] = report.findings
  string.contains(finding.detail, ":batchmany") |> should.be_true()
  string.contains(finding.detail, "ListPostsBatch") |> should.be_true()
}

pub fn verify_rejects_execresult_under_native_runtime_test() {
  // :execresult is valid on the raw path but incompatible with
  // the native runtime. `verify` must honour the runtime flag on
  // the block when running this check so a native project
  // cannot ship code the generator would refuse.
  let cfg =
    model.Config(version: 2, sql: [
      make_block_with(
        "test/fixtures/all_commands_schema.sql",
        "test/fixtures/execresult_query.sql",
        "src/verify_execresult_out",
        model.SQLite,
        model.Native,
      ),
    ])
  let report = verify.verify_config(cfg)
  let assert [finding] = report.findings
  string.contains(finding.detail, ":execresult") |> should.be_true()
  string.contains(finding.detail, "UpdatePost") |> should.be_true()
}

pub fn verify_execresult_under_raw_runtime_is_allowed_test() {
  // The same fixture must pass verification when the block
  // targets the raw runtime — :execresult is only forbidden in
  // native mode. This guards against an over-eager check that
  // would fire regardless of runtime.
  let cfg =
    model.Config(version: 2, sql: [
      make_block_with(
        "test/fixtures/all_commands_schema.sql",
        "test/fixtures/execresult_query.sql",
        "src/verify_execresult_raw_out",
        model.SQLite,
        model.Raw,
      ),
    ])
  let report = verify.verify_config(cfg)
  report.findings |> should.equal([])
}

// Note: the non-PostgreSQL array-parameter check
// (`validate_array_engine_support`) is also shared with `generate`
// via `sqlode/internal/query_validation`. We do not add a fixture-based
// regression test here because the current SQLite schema pipeline
// does not surface `ArrayType` on inferred params for
// `TEXT[]` / `INTEGER[]` columns, so neither command actually
// reaches the rejection branch today. If a future change produces
// array-typed params on a non-PostgreSQL engine, both `generate`
// and `verify` will reject it with an identical message through
// the shared validator.

// ============================================================
// Issue #504: verify must detect empty query lists
// ============================================================

pub fn verify_rejects_empty_query_file_test() {
  // A query file with no valid annotations should produce a finding,
  // matching what `generate` would report as NoQueriesGenerated.
  let cfg =
    model.Config(version: 2, sql: [
      make_block(
        "test/fixtures/verify_ok_schema.sql",
        "test/fixtures/verify_empty_query.sql",
        "src/verify_empty_query_out",
        option.None,
      ),
    ])
  let report = verify.verify_config(cfg)
  let assert [finding] = report.findings
  string.contains(finding.detail, "no queries") |> should.be_true()
}
