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
import sqlode/internal/config
import sqlode/internal/generate
import sqlode/internal/model
import sqlode/internal/naming
import sqlode/internal/query_analyzer
import sqlode/internal/query_ir

/// Outcome of a single verification pass. A report with an empty
/// `findings` list means every block in the config parsed, analysed
/// and satisfied the configured static policies.
pub type Report {
  Report(findings: List(Finding), warnings: List(generate.Warning))
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
  let resolved = generate.resolve_config_paths(cfg, base_dir)
  Ok(verify_config(resolved))
}

/// Verify an already-loaded and path-resolved `model.Config`. Broken
/// out so tests can build a config value directly and assert against
/// the findings list without touching the filesystem.
pub fn verify_config(cfg: model.Config) -> Report {
  let naming_ctx = naming.new()
  let #(findings, warnings) =
    cfg.sql
    |> list.map(verify_block(naming_ctx, _))
    |> list.unzip
  Report(
    findings: list.flatten(findings),
    warnings: warnings |> list.flatten |> list.unique,
  )
}

/// Runs the same loading, analysis and checks as `generate` through
/// the functions it exports, so both commands reach the same verdict.
/// Unlike `generate`, every query is analysed on its own (the analyser
/// keeps no state between queries), so one broken query does not hide
/// the next.
fn verify_block(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
) -> #(List(Finding), List(generate.Warning)) {
  let out = block.gleam.out
  let finding = fn(error) {
    Finding(block_out: out, detail: generate.error_to_string(error))
  }
  let loaded =
    generate.validate_out_path(out)
    |> result.try(fn(_) { generate.load_catalog(block) })
  case loaded {
    Error(error) -> #([finding(error)], [])
    Ok(#(catalog, warnings)) -> {
      // verify reports only the custom type warnings; the schema
      // warnings are what `strict_views` turns into findings.
      let warnings =
        list.filter(warnings, fn(warning) {
          case warning {
            generate.CustomTypeAlias(..) -> True
            generate.SchemaWarning(..) -> False
          }
        })
      let findings = case generate.load_queries(naming_ctx, block) {
        Error(error) -> [finding(error)]
        Ok(queries) -> {
          let checked =
            analyze_each(naming_ctx, block, catalog, queries)
            |> result.try(fn(analyzed) {
              generate.check_analyzed(naming_ctx, block, catalog, analyzed)
              |> result.map_error(list.wrap)
            })
          case checked {
            Error(errors) -> list.map(errors, finding)
            Ok([]) -> [
              Finding(
                block_out: out,
                detail: "SQD5001: no queries were generated — query files are empty or contain no valid annotations",
              ),
            ]
            Ok(analyzed) ->
              enforce_query_parameter_limit(
                out,
                analyzed,
                block.gleam.query_parameter_limit,
              )
          }
        }
      }
      #(findings, warnings)
    }
  }
}

fn analyze_each(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  catalog: model.Catalog,
  queries: List(query_ir.TokenizedQuery),
) -> Result(List(model.AnalyzedQuery), List(generate.GenerateError)) {
  let #(analyzed, errors) =
    queries
    |> list.map(fn(query) {
      query_analyzer.analyze_queries(block.engine, catalog, naming_ctx, [query])
      |> result.map_error(generate.QueryAnalysisFailed(_, block.engine))
    })
    |> result.partition
  case errors {
    [] -> Ok(analyzed |> list.reverse |> list.flatten)
    _ -> Error(list.reverse(errors))
  }
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
