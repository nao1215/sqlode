//// Prints what sqlode infers for each query of a SQLite project, one line
//// per query, for `scripts/differential_sqlite.py` to compare with what
//// SQLite itself reports for the same statement:
////
//// ```text
//// <name>\t<returns rows: true/false>\t<parameter count>\t<result column names, comma separated>\t<SQL>
//// ```
////
//// A query sqlode refuses to analyse is printed as
//// `rejected\t<name>\t<SQL>\t<error>`.
////
//// The SQL is the text the generated code sends (placeholders expanded to
//// `?N`). Queries that use `sqlode.slice` are skipped, since their
//// parameter count depends on the list lengths at run time.
////
//// Usage: `gleam run -m sqlite_oracle_dump -- <schema.sql> <query.sql>`

import argv
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import simplifile
import sqlode/internal/model
import sqlode/internal/naming
import sqlode/internal/query_analyzer
import sqlode/internal/query_analyzer/context
import sqlode/internal/query_parser
import sqlode/internal/schema_parser
import sqlode/runtime

pub fn main() -> Nil {
  let assert [schema_path, query_path] = argv.load().arguments
    as "usage: sqlite_oracle_dump <schema.sql> <query.sql>"
  let naming_ctx = naming.new()
  let assert Ok(schema_text) = simplifile.read(schema_path)
    as "the schema file is readable"
  let assert Ok(query_text) = simplifile.read(query_path)
    as "the query file is readable"
  let assert Ok(#(catalog, _)) =
    schema_parser.parse_files([#(schema_path, schema_text)], model.SQLite)
    as "the schema parses"
  let assert Ok(parsed) =
    query_parser.parse_file(query_path, model.SQLite, naming_ctx, query_text)
    as "the queries parse"
  // One query at a time, so a query sqlode rejects is reported by name
  // instead of hiding the rest of the file.
  list.each(parsed, fn(query) {
    case
      query_analyzer.analyze_queries(model.SQLite, catalog, naming_ctx, [query])
    {
      Ok([analyzed]) ->
        case has_slice(analyzed.base.macros) {
          True -> Nil
          False -> io.println(line(analyzed))
        }
      Ok(_) -> Nil
      Error(error) ->
        io.println(
          "rejected\t"
          <> query.base.name
          <> "\t"
          <> string.replace(query.base.sql, "\n", " ")
          <> "\t"
          <> string.replace(
            context.analysis_error_to_string(error, model.SQLite),
            "\n",
            " ",
          ),
        )
    }
  })
}

fn has_slice(macros: List(model.Macro)) -> Bool {
  list.any(macros, fn(m) {
    case m {
      model.MacroSlice(..) -> True
      _ -> False
    }
  })
}

fn line(query: model.AnalyzedQuery) -> String {
  let sql =
    runtime.prepare(
      runtime.RawQuery(
        name: query.base.name,
        sql: query.base.sql,
        command: model.generated_command(query.base.command),
        param_count: query.base.param_count,
        placeholder_style: runtime.QuestionNumbered,
        encode: fn(_) { [] },
        slice_info: fn(_) { [] },
      ),
      Nil,
    ).0
    |> string.replace("\n", " ")
    |> string.replace("\t", " ")
  let columns =
    query.result_columns
    |> list.flat_map(fn(item) {
      case item {
        model.ScalarResult(column) -> [column.name]
        model.EmbeddedResult(embedded) ->
          list.map(embedded.columns, fn(column) { column.name })
      }
    })
  string.join(
    [
      query.base.name,
      case model.is_result_command(query.base.command) {
        True -> "true"
        False -> "false"
      },
      int.to_string(list.length(query.params)),
      string.join(columns, ","),
      sql,
    ],
    "\t",
  )
}
