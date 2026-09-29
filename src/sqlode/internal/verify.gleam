//// `sqlode verify` — static, read-only verification lane.
////
//// `generate` stops at the first error it encounters so codegen can
//// still produce useful output for a partially-working project.
//// `verify` is the opposite: it walks every block in the config,
//// runs the same schema parsing and query analysis the generator
//// uses, collects every failure it can see, and layers additional
//// static checks on top (today: `query_parameter_limit`
//// enforcement). It never writes files.

import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlode/internal/config
import sqlode/internal/generate
import sqlode/internal/model
import sqlode/internal/naming
import sqlode/internal/query_analyzer
import sqlode/internal/query_ir
import sqlode/internal/query_parser
import sqlode/internal/query_validation
import sqlode/internal/schema_parser
import sqlode/internal/sql_paths

/// Outcome of a single verification pass. A report with an empty
/// `findings` list means every block in the config parsed, analysed
/// and satisfied the configured static policies.
pub type Report {
  Report(findings: List(Finding))
}

/// One concrete problem the verifier found. `block_out` names the
/// `sql.gen.gleam.out` of the block the finding applies to so
/// reports with multiple blocks stay attributable without inventing
/// a synthetic block identity.
pub type Finding {
  Finding(block_out: String, detail: String)
}

pub type VerifyError {
  ConfigError(config.ConfigError)
}

/// Entry point. Loads the config at `config_path`, resolves relative
/// paths the same way `generate.run` does, and returns a report.
/// The result is `Ok(Report)` even when the project has problems —
/// only unrecoverable errors (missing config, YAML syntax errors)
/// surface as `Error`.
pub fn run(config_path: String) -> Result(Report, VerifyError) {
  use cfg <- result.try(
    config.load(config_path)
    |> result.map_error(ConfigError),
  )
  let base_dir = filepath.directory_name(config_path)
  let resolved = resolve_paths(cfg, base_dir)
  Ok(verify_config(resolved))
}

/// Verify an already-loaded and path-resolved `model.Config`. Broken
/// out so tests can build a config value directly and assert against
/// the findings list without touching the filesystem.
pub fn verify_config(cfg: model.Config) -> Report {
  let naming_ctx = naming.new()
  let findings =
    list.flat_map(cfg.sql, fn(block) { verify_block(naming_ctx, block) })
  Report(findings: findings)
}

fn verify_block(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
) -> List(Finding) {
  let out = block.gleam.out
  case load_catalog(block) {
    Error(detail) -> [Finding(block_out: out, detail: detail)]
    Ok(catalog) ->
      case load_and_analyze(naming_ctx, block, catalog) {
        Error(details) ->
          list.map(details, fn(detail) { Finding(block_out: out, detail:) })
        Ok(analyzed) ->
          case analyzed {
            [] -> [
              Finding(
                block_out: out,
                detail: "SQD5001: no queries were generated — query files are empty or contain no valid annotations",
              ),
            ]
            _ ->
              enforce_query_parameter_limit(
                out,
                analyzed,
                block.gleam.query_parameter_limit,
              )
          }
      }
  }
}

// ============================================================
// Schema / query pipeline (read-only mirror of generate.load_*)
// ============================================================

fn load_catalog(block: model.SqlBlock) -> Result(model.Catalog, String) {
  use entries <- result.try(read_files(block.schema, generate.SchemaReadError))
  case schema_parser.parse_files_with_engine(entries, block.engine) {
    Ok(#(catalog, warnings)) ->
      case block.gleam.strict_views, warnings {
        True, [_, ..] -> {
          let formatted =
            warnings
            |> list.map(schema_parser.warning_to_string)
            |> string.join("\n  ")
          Error(
            "SQD2005: strict_views is enabled but the schema produced resolution warnings:\n  "
            <> formatted,
          )
        }
        _, _ -> Ok(catalog)
      }
    Error(error) -> Error(schema_parser.error_to_string(error))
  }
}

/// Errors are returned as a list so that every query the analyser rejects
/// is reported in one run, not only the first; the later checks run on
/// fully analysed queries and stay single.
fn load_and_analyze(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  catalog: model.Catalog,
) -> Result(List(model.AnalyzedQuery), List(String)) {
  use analyzed <- result.try(analyze_each(naming_ctx, block, catalog))
  validate_analyzed(block, analyzed) |> result.map_error(fn(e) { [e] })
}

fn analyze_each(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  catalog: model.Catalog,
) -> Result(List(model.AnalyzedQuery), List(String)) {
  use entries <- result.try(
    read_files(block.queries, generate.QueryReadError)
    |> result.map_error(fn(e) { [e] }),
  )
  use queries <- result.try(
    parse_all_queries(entries, block.engine, naming_ctx)
    |> result.map_error(fn(e) { [e] }),
  )
  use Nil <- result.try(
    query_validation.validate_no_duplicate_names(queries)
    |> result.map_error(fn(e) { [query_validation.error_to_string(e)] }),
  )
  // Each query is analysed on its own (the analyser keeps no state
  // between queries), so one broken query does not hide the next.
  let results =
    list.map(queries, fn(query) {
      query_analyzer.analyze_queries(block.engine, catalog, naming_ctx, [query])
    })
  case
    list.filter_map(results, fn(analysis) {
      case analysis {
        Error(error) ->
          Ok(query_analyzer.analysis_error_to_string(error, block.engine))
        Ok(_) -> Error(Nil)
      }
    })
  {
    [] -> Ok(list.flat_map(results, result.unwrap(_, [])))
    errors -> Error(errors)
  }
}

fn validate_analyzed(
  block: model.SqlBlock,
  analyzed: List(model.AnalyzedQuery),
) -> Result(List(model.AnalyzedQuery), String) {
  use Nil <- result.try(
    query_validation.validate_unsupported_annotations(analyzed)
    |> result.map_error(query_validation.error_to_string),
  )
  use Nil <- result.try(
    query_validation.validate_array_engine_support(block.engine, analyzed)
    |> result.map_error(query_validation.error_to_string),
  )
  use Nil <- result.try(
    query_validation.validate_slice_placement(analyzed)
    |> result.map_error(query_validation.error_to_string),
  )
  use Nil <- result.try(case block.gleam.runtime {
    model.Native ->
      query_validation.validate_native_annotations(analyzed)
      |> result.map_error(query_validation.error_to_string)
    model.Raw -> Ok(Nil)
  })
  let analyzed =
    generate.apply_column_renames(analyzed, block.overrides.column_renames)
  let analyzed = generate.disambiguate_param_names(analyzed)
  Ok(analyzed)
}

fn parse_all_queries(
  entries: List(#(String, String)),
  engine: model.Engine,
  naming_ctx: naming.NamingContext,
) -> Result(List(query_ir.TokenizedQuery), String) {
  entries
  |> list.try_fold([], fn(acc, entry) {
    let #(path, content) = entry
    case query_parser.parse_file(path, engine, naming_ctx, content) {
      Ok(qs) -> Ok(list.append(acc, qs))
      Error(err) -> Error(query_parser.error_to_string(err))
    }
  })
}

/// `read_error` is `generate.SchemaReadError` or `generate.QueryReadError`,
/// so a path that cannot be read is reported as `generate` reports it.
fn read_files(
  paths: List(String),
  read_error: fn(String, String) -> generate.GenerateError,
) -> Result(List(#(String, String)), String) {
  let to_string = fn(path, detail) {
    generate.error_to_string(read_error(path, detail))
  }
  use expanded <- result.try(sql_paths.expand(paths, to_string))
  expanded
  |> list.try_map(fn(path) {
    case simplifile.read(path) {
      Ok(content) -> Ok(#(path, content))
      Error(reason) ->
        Error(to_string(
          path,
          "Failed to read file: " <> simplifile.describe_error(reason),
        ))
    }
  })
}

// ============================================================
// Static policies
// ============================================================

fn enforce_query_parameter_limit(
  block_out: String,
  queries: List(model.AnalyzedQuery),
  limit: Option(Int),
) -> List(Finding) {
  case limit {
    None -> []
    Some(n) ->
      case n <= 0 {
        True -> []
        False ->
          list.filter_map(queries, fn(q) {
            let count = list.length(q.params)
            case count > n {
              True ->
                Ok(Finding(
                  block_out: block_out,
                  detail: "SQD4012: query \""
                    <> q.base.name
                    <> "\" has "
                    <> int.to_string(count)
                    <> " inferred parameter(s), exceeds query_parameter_limit "
                    <> int.to_string(n),
                ))
              False -> Error(Nil)
            }
          })
      }
  }
}

// ============================================================
// Path resolution and reporting
// ============================================================

fn resolve_paths(cfg: model.Config, base_dir: String) -> model.Config {
  let sql =
    list.map(cfg.sql, fn(block) {
      let schema = list.map(block.schema, resolve_path(base_dir, _))
      let queries = list.map(block.queries, resolve_path(base_dir, _))
      let gleam =
        model.GleamOutput(
          ..block.gleam,
          out: resolve_path(base_dir, block.gleam.out),
        )
      model.SqlBlock(..block, schema: schema, queries: queries, gleam: gleam)
    })
  model.Config(..cfg, sql: sql)
}

fn resolve_path(base_dir: String, path: String) -> String {
  case filepath.is_absolute(path) {
    True -> path
    False ->
      case filepath.expand(filepath.join(base_dir, path)) {
        Ok(expanded) -> expanded
        Error(_) -> filepath.join(base_dir, path)
      }
  }
}

pub fn report_to_string(report: Report) -> String {
  case report.findings {
    [] -> "All checks passed."
    findings ->
      findings
      |> list.map(format_finding)
      |> string.join("\n")
  }
}

fn format_finding(finding: Finding) -> String {
  "[" <> finding.block_out <> "] " <> finding.detail
}

pub fn error_to_string(error: VerifyError) -> String {
  let ConfigError(inner) = error
  config.error_to_string(inner)
}
