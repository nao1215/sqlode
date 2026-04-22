//// `sqlode verify` — static, read-only verification lane.
////
//// `generate` stops at the first error it encounters so codegen can
//// still produce useful output for a partially-working project.
//// `verify` is the opposite: it walks every block in the config,
//// runs the same schema parsing and query analysis the generator
//// uses, collects every failure it can see, and layers additional
//// static checks on top (today: `query_parameter_limit`
//// enforcement). It never writes files.
////
//// The command is intended as the first phase of the Issue #395
//// verification roadmap — later phases will add DB-backed analysis
//// (`database` / `analyzer` config concepts) and execution-lane
//// validation. Keeping the static surface here means those later
//// phases can grow `Finding` with new variants without reshaping
//// the command wiring.

import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlode/config
import sqlode/model
import sqlode/naming
import sqlode/query_analyzer
import sqlode/query_ir
import sqlode/query_parser
import sqlode/schema_parser
import sqlode/sql_paths

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
        Error(detail) -> [Finding(block_out: out, detail: detail)]
        Ok(analyzed) ->
          enforce_query_parameter_limit(
            out,
            analyzed,
            block.gleam.query_parameter_limit,
          )
      }
  }
}

// ============================================================
// Schema / query pipeline (read-only mirror of generate.load_*)
// ============================================================

fn load_catalog(block: model.SqlBlock) -> Result(model.Catalog, String) {
  use entries <- result.try(read_files(block.schema))
  case schema_parser.parse_files_with_engine(entries, block.engine) {
    Ok(#(catalog, warnings)) ->
      case block.gleam.strict_views, warnings {
        True, [_, ..] -> {
          let formatted =
            warnings
            |> list.map(schema_parser.warning_to_string)
            |> string.join("\n  ")
          Error("strict_views policy rejects the schema:\n  " <> formatted)
        }
        _, _ -> Ok(catalog)
      }
    Error(error) -> Error(schema_parser.error_to_string(error))
  }
}

fn load_and_analyze(
  naming_ctx: naming.NamingContext,
  block: model.SqlBlock,
  catalog: model.Catalog,
) -> Result(List(model.AnalyzedQuery), String) {
  use entries <- result.try(read_files(block.queries))
  use queries <- result.try(parse_all_queries(entries, block.engine, naming_ctx))
  query_analyzer.analyze_queries(block.engine, catalog, naming_ctx, queries)
  |> result.map_error(query_analyzer.analysis_error_to_string)
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
      Error(err) -> Error(path <> ": " <> query_parser.error_to_string(err))
    }
  })
}

fn read_files(paths: List(String)) -> Result(List(#(String, String)), String) {
  use expanded <- result.try(
    sql_paths.expand(paths, fn(path, detail) { path <> ": " <> detail }),
  )
  expanded
  |> list.try_map(fn(path) {
    case simplifile.read(path) {
      Ok(content) -> Ok(#(path, content))
      Error(reason) -> Error(path <> ": " <> simplifile.describe_error(reason))
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
                  detail: "query \""
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
