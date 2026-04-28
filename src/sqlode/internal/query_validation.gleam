//// Post-parse query validation shared by `generate` and `verify`.
////
//// These checks reject configurations that would otherwise reach
//// the codegen stage in a state the generator cannot express
//// safely. Centralising them here means `verify` and `generate`
//// reach the same verdict for any given config: `verify` can be
//// used as a trustworthy pre-generation CI gate, and the checks
//// cannot drift apart again by accident.

import gleam/dict
import gleam/list
import gleam/string
import sqlode/internal/model
import sqlode/internal/query_ir
import sqlode/runtime

/// A problem a post-parse check surfaced. Callers wrap the variant
/// in their own error type (a `GenerateError` for the generator, a
/// `Finding` string for the verifier) so the shared diagnostic text
/// stays identical across commands.
pub type ValidationError {
  DuplicateName(name: String, paths: List(String))
  NormalizedNameCollision(
    function_name: String,
    names: List(String),
    paths: List(String),
  )
  UnsupportedAnnotation(query_name: String, command: String, detail: String)
  UnsupportedArrayForEngine(query_name: String, engine: String)
}

/// Reject two tokenized queries that declare the same annotation
/// name, or whose names normalize to the same Gleam identifier
/// (the snake_case `function_name` that queries/params/decoders
/// are derived from). Either shape would leave the generator
/// emitting duplicate declarations and fail the Gleam compile.
/// Literal duplicates are reported first so operators see the
/// simpler diagnostic when both cases hit at once.
pub fn validate_no_duplicate_names(
  queries: List(query_ir.TokenizedQuery),
) -> Result(Nil, ValidationError) {
  case find_duplicate_group(queries, fn(q) { q.base.name }) {
    Ok(#(name, dupes)) -> {
      let paths =
        dupes
        |> list.map(fn(q) { q.base.source_path })
        |> list.unique
      Error(DuplicateName(name:, paths:))
    }
    Error(Nil) ->
      case find_duplicate_group(queries, fn(q) { q.base.function_name }) {
        Ok(#(function_name, colliding)) -> {
          let names =
            colliding |> list.map(fn(q) { q.base.name }) |> list.unique
          let paths =
            colliding |> list.map(fn(q) { q.base.source_path }) |> list.unique
          Error(NormalizedNameCollision(function_name:, names:, paths:))
        }
        Error(Nil) -> Ok(Nil)
      }
  }
}

fn find_duplicate_group(
  queries: List(query_ir.TokenizedQuery),
  key: fn(query_ir.TokenizedQuery) -> String,
) -> Result(#(String, List(query_ir.TokenizedQuery)), Nil) {
  list.group(queries, key)
  |> dict.to_list
  |> list.find(fn(entry) { list.length(entry.1) > 1 })
}

/// Reject annotations that are not yet supported by any codegen
/// path (`:batchone`, `:batchmany`, `:batchexec`, `:copyfrom`).
/// The failure names a supported alternative so operators can fix
/// the annotation without digging through docs.
pub fn validate_unsupported_annotations(
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, ValidationError) {
  let unsupported = fn(command: runtime.QueryCommand) -> Bool {
    case command {
      runtime.QueryBatchOne
      | runtime.QueryBatchMany
      | runtime.QueryBatchExec
      | runtime.QueryCopyFrom -> True
      _ -> False
    }
  }
  case list.find(queries, fn(q) { unsupported(q.base.command) }) {
    Ok(q) -> {
      let #(command, alternative) = case q.base.command {
        runtime.QueryBatchOne -> #(":batchone", ":one")
        runtime.QueryBatchMany -> #(":batchmany", ":many")
        runtime.QueryBatchExec -> #(":batchexec", ":exec")
        runtime.QueryCopyFrom -> #(":copyfrom", ":exec")
        _ -> #("", ":exec")
      }
      Error(UnsupportedAnnotation(
        query_name: q.base.name,
        command: command,
        detail: command
          <> " is not yet supported. Use "
          <> alternative
          <> " instead, or add '-- sqlode:skip' before the annotation to bypass this query",
      ))
    }
    Error(_) -> Ok(Nil)
  }
}

/// Reject array parameters for engines that cannot carry them.
/// Only PostgreSQL supports native array binding at the adapter
/// layer today.
pub fn validate_array_engine_support(
  engine: model.Engine,
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, ValidationError) {
  case engine {
    model.PostgreSQL -> Ok(Nil)
    _ -> {
      let has_array = fn(q: model.AnalyzedQuery) {
        list.any(q.params, fn(p) {
          case p.scalar_type {
            model.ArrayType(_) -> True
            _ -> False
          }
        })
      }
      case list.find(queries, has_array) {
        Ok(q) ->
          Error(UnsupportedArrayForEngine(
            query_name: q.base.name,
            engine: model.engine_to_string(engine),
          ))
        Error(_) -> Ok(Nil)
      }
    }
  }
}

/// Reject annotations that clash with the native runtime. Call
/// only when the block targets the native runtime; raw-runtime
/// projects can still emit `:execresult` and should not be
/// filtered by this check.
pub fn validate_native_annotations(
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, ValidationError) {
  case list.find(queries, fn(q) { q.base.command == runtime.QueryExecResult }) {
    Ok(q) ->
      Error(UnsupportedAnnotation(
        query_name: q.base.name,
        command: ":execresult",
        detail: ":execresult is not supported with native runtime. Use :exec, :execrows, or :execlastid instead",
      ))
    Error(_) -> Ok(Nil)
  }
}

pub fn error_to_string(error: ValidationError) -> String {
  case error {
    DuplicateName(name:, paths:) ->
      "duplicate query name \""
      <> name
      <> "\" found in: "
      <> string.join(paths, ", ")
    NormalizedNameCollision(function_name:, names:, paths:) ->
      "query names "
      <> quote_join(names)
      <> " all normalize to the generated identifier \""
      <> function_name
      <> "\" (found in: "
      <> string.join(paths, ", ")
      <> "). Rename one of them so the derived function, params, row, and decoder identifiers are unique."
    UnsupportedAnnotation(query_name:, command:, detail:) ->
      "Query " <> query_name <> " uses " <> command <> ": " <> detail
    UnsupportedArrayForEngine(query_name:, engine:) ->
      "Query \""
      <> query_name
      <> "\": array parameters are not supported for engine \""
      <> engine
      <> "\". Arrays are only supported with PostgreSQL"
  }
}

fn quote_join(names: List(String)) -> String {
  names
  |> list.map(fn(n) { "\"" <> n <> "\"" })
  |> string.join(", ")
}
