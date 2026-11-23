//// Post-parse query validation shared by `generate` and `verify`.
////
//// These checks reject configurations that would otherwise reach
//// the codegen stage in a state the generator cannot express
//// safely. Centralising them here means `verify` and `generate`
//// reach the same verdict for any given config: `verify` can be
//// used as a trustworthy pre-generation CI gate, and the checks
//// cannot drift apart again by accident.

import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import sqlode/internal/lexer
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
  SliceInsideQuantifier(query_name: String)
  /// The native adapter's driver returns (or, for a parameter, expects)
  /// a value of this type in a shape the generated `String` cannot
  /// hold. `subject` is the column name or `$N`.
  UnsupportedNativeType(
    query_name: String,
    subject: String,
    is_parameter: Bool,
    sql_type: String,
    engine: model.Engine,
  )
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
  let unsupported = fn(query: model.AnalyzedQuery) {
    model.unsupported_command_alternative(query.base.command)
    |> result.map(fn(alternative) { #(query, alternative) })
  }
  case list.find_map(queries, unsupported) {
    Ok(#(q, alternative)) -> {
      let command = model.annotation_text(q.base.command)
      let alternative = model.annotation_text(model.Command(alternative))
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
/// layer today, so an inferred `ArrayType` parameter (a query
/// reading a PostgreSQL `TEXT[]` column) is rejected on SQLite and
/// MySQL. `sqlode.slice(...)` is not an array parameter: the
/// generated code flattens the list into one scalar value per
/// element and `runtime.prepare` expands the marker into that many
/// placeholders, so it works on every engine.
pub fn validate_array_engine_support(
  engine: model.Engine,
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, ValidationError) {
  case engine {
    model.PostgreSQL -> Ok(Nil)
    _ -> {
      let engine_name = model.engine_to_string(engine)
      let has_array_param = fn(q: model.AnalyzedQuery) {
        list.any(q.params, fn(p) {
          case p.scalar_type {
            model.ArrayType(_) -> True
            _ -> False
          }
        })
      }
      case list.find(queries, has_array_param) {
        Ok(q) ->
          Error(UnsupportedArrayForEngine(
            query_name: q.base.name,
            engine: engine_name,
          ))
        Error(_) -> Ok(Nil)
      }
    }
  }
}

/// Reject `sqlode.slice(...)` written inside `ANY` / `ALL` / `SOME`.
/// A slice expands to one placeholder per element, so
/// `col = ANY(sqlode.slice(ids))` becomes `col = ANY($1, $2)`, which
/// PostgreSQL rejects as a syntax error (and `ANY($1)` with a single
/// scalar as "requires array on right side"). The query could never
/// run, so it is stopped before any code is written.
pub fn validate_slice_placement(
  engine: model.Engine,
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, ValidationError) {
  case
    list.find(queries, fn(q) {
      slice_inside_quantifier(lexer.tokenize(q.base.sql, engine))
    })
  {
    Ok(q) -> Error(SliceInsideQuantifier(query_name: q.base.name))
    Error(_) -> Ok(Nil)
  }
}

fn slice_inside_quantifier(tokens: List(lexer.Token)) -> Bool {
  case tokens {
    [] -> False
    [lexer.Keyword(quantifier), lexer.LParen, lexer.Placeholder(marker), ..rest]
      if quantifier == "any" || quantifier == "all" || quantifier == "some"
    ->
      string.starts_with(marker, "__sqlode_slice_")
      || slice_inside_quantifier(rest)
    [_, ..rest] -> slice_inside_quantifier(rest)
  }
}

/// Reject annotations that clash with the native runtime. Call
/// only when the block targets the native runtime; raw-runtime
/// projects can still emit `:execresult` and should not be
/// filtered by this check.
pub fn validate_native_annotations(
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, ValidationError) {
  case
    list.find(queries, fn(q) {
      q.base.command == model.Command(runtime.ExecResult)
    })
  {
    Ok(q) ->
      Error(UnsupportedAnnotation(
        query_name: q.base.name,
        command: ":execresult",
        detail: ":execresult is not supported with native runtime. Use :exec, :execrows, or :execlastid instead",
      ))
    Error(_) -> Ok(Nil)
  }
}

/// Dates, times and timestamps reach the generated code as `String`,
/// and so do PostgreSQL UUIDs. pog returns all of them as other values
/// (gleam_time records, a 16-byte BitArray) and only accepts dates and
/// times as gleam_time values, and the MySQL driver returns dates and
/// times as tuples. Stop at generation time instead of writing an
/// adapter whose calls fail with a decode error on every row.
pub fn validate_native_types(
  engine: model.Engine,
  queries: List(model.AnalyzedQuery),
) -> Result(Nil, ValidationError) {
  list.try_each(queries, fn(query) {
    let unsupported = fn(subject, is_parameter, scalar_type) {
      case native_unsupported_type(engine, is_parameter, scalar_type) {
        Ok(sql_type) ->
          Error(UnsupportedNativeType(
            query_name: query.base.name,
            subject:,
            is_parameter:,
            sql_type:,
            engine:,
          ))
        Error(Nil) -> Ok(Nil)
      }
    }
    use Nil <- result.try(
      list.try_each(query.params, fn(param) {
        unsupported("$" <> int.to_string(param.index), True, param.scalar_type)
      }),
    )
    list.try_each(query.result_columns, fn(item) {
      case item {
        model.ScalarResult(column) ->
          unsupported(column.name, False, column.scalar_type)
        model.EmbeddedResult(embedded) ->
          list.try_each(embedded.columns, fn(column) {
            unsupported(column.name, False, column.scalar_type)
          })
      }
    })
  })
}

/// The SQL type name of `scalar_type` when the engine's native driver
/// cannot carry it as the generated `String`.
fn native_unsupported_type(
  engine: model.Engine,
  is_parameter: Bool,
  scalar_type: model.ScalarType,
) -> Result(String, Nil) {
  case scalar_type, engine, is_parameter {
    model.CustomType(underlying:, ..), _, _
    | model.ArrayType(element: underlying), _, _
    -> native_unsupported_type(engine, is_parameter, underlying)
    model.DateTimeType, model.PostgreSQL, _
    | model.DateTimeType, model.MySQL, False
    -> Ok("TIMESTAMP")
    model.DateType, model.PostgreSQL, _ | model.DateType, model.MySQL, False ->
      Ok("DATE")
    model.TimeType, model.PostgreSQL, _ | model.TimeType, model.MySQL, False ->
      Ok("TIME or INTERVAL")
    model.UuidType, model.PostgreSQL, False -> Ok("UUID")
    _, _, _ -> Error(Nil)
  }
}

pub fn error_to_string(error: ValidationError) -> String {
  error_code(error) <> ": " <> error_message(error)
}

/// The stable code for each error, documented in `doc/errors.md`.
fn error_code(error: ValidationError) -> String {
  case error {
    DuplicateName(..) -> "SQD3007"
    NormalizedNameCollision(..) -> "SQD3008"
    UnsupportedAnnotation(..) -> "SQD4009"
    UnsupportedArrayForEngine(..) -> "SQD4010"
    SliceInsideQuantifier(..) -> "SQD4011"
    UnsupportedNativeType(..) -> "SQD4013"
  }
}

fn error_message(error: ValidationError) -> String {
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
    SliceInsideQuantifier(query_name:) ->
      "Query \""
      <> query_name
      <> "\": sqlode.slice() cannot be used inside ANY, ALL or SOME. It expands to one placeholder per element, and ANY takes a single array. Write `col IN (sqlode.slice(ids))`, or pass the list as one array with `col = ANY($1)`"
    UnsupportedNativeType(
      query_name:,
      subject:,
      is_parameter:,
      sql_type:,
      engine:,
    ) -> {
      let #(driver, hint) = case is_parameter, engine {
        True, _ -> #(
          "pog",
          "send it as text and cast it to the column's type in SQL, as in `"
            <> subject
            <> "::text::timestamptz` for a TIMESTAMPTZ column",
        )
        False, model.MySQL -> #(
          "shork",
          "select it as text, as in `CAST("
            <> subject
            <> " AS CHAR) AS "
            <> subject
            <> "`",
        )
        False, _ -> #(
          "pog",
          "select it as text, as in `"
            <> subject
            <> "::text AS "
            <> subject
            <> "`",
        )
      }
      "Query \""
      <> query_name
      <> "\": the "
      <> driver
      <> " adapter cannot "
      <> case is_parameter {
        True -> "send parameter "
        False -> "read column "
      }
      <> subject
      <> " ("
      <> sql_type
      <> ") as the generated String: "
      <> driver
      <> " "
      <> case is_parameter {
        True -> "takes"
        False -> "returns"
      }
      <> " it as a different value. Either "
      <> hint
      <> ", or use runtime: raw and convert the value with your driver"
    }
  }
}

fn quote_join(names: List(String)) -> String {
  names
  |> list.map(fn(n) { "\"" <> n <> "\"" })
  |> string.join(", ")
}
