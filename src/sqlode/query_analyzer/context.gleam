import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sqlode/model
import sqlode/naming

pub type AnalysisError {
  TableNotFound(query_name: String, table_name: String)
  ColumnNotFound(query_name: String, table_name: String, column_name: String)
  ParameterTypeNotInferred(query_name: String, param_index: Int)
  UnrecognizedCastType(query_name: String, param_index: Int, cast_type: String)
  CompoundColumnCountMismatch(
    query_name: String,
    first_count: Int,
    branch_count: Int,
  )
  UnsupportedExpression(query_name: String, expression: String)
}

pub fn analysis_error_to_string(error: AnalysisError) -> String {
  case error {
    TableNotFound(query_name:, table_name:) ->
      "Query \""
      <> query_name
      <> "\": table \""
      <> table_name
      <> "\" not found in schema"
    ColumnNotFound(query_name:, table_name:, column_name:) ->
      "Query \""
      <> query_name
      <> "\": column \""
      <> column_name
      <> "\" not found in table \""
      <> table_name
      <> "\""
    ParameterTypeNotInferred(query_name:, param_index:) ->
      "Query \""
      <> query_name
      <> "\": could not infer type for parameter $"
      <> int.to_string(param_index)
      <> ". Use a type cast (e.g. $"
      <> int.to_string(param_index)
      <> "::int) to specify the type"
    UnrecognizedCastType(query_name:, param_index:, cast_type:) ->
      "Query \""
      <> query_name
      <> "\": unrecognized cast type \""
      <> cast_type
      <> "\" for parameter $"
      <> int.to_string(param_index)
    CompoundColumnCountMismatch(query_name:, first_count:, branch_count:) ->
      "Query \""
      <> query_name
      <> "\": compound query branch has "
      <> int.to_string(branch_count)
      <> " columns, but the first branch has "
      <> int.to_string(first_count)
    UnsupportedExpression(query_name:, expression:) ->
      "Query \""
      <> query_name
      <> "\": unsupported expression \""
      <> expression
      <> "\", cannot infer result type. Use CAST to specify the type explicitly"
  }
}

pub type AnalyzerContext {
  AnalyzerContext(naming: naming.NamingContext)
}

pub fn new(naming_ctx: naming.NamingContext) -> AnalyzerContext {
  AnalyzerContext(naming: naming_ctx)
}

pub fn find_column(
  catalog: model.Catalog,
  table_name: String,
  column_name: String,
) -> Option(model.Column) {
  case
    catalog.tables
    |> list.find(fn(table) {
      table.name == naming.normalize_identifier(table_name)
    })
  {
    Ok(table) ->
      table.columns
      |> list.find(fn(column) {
        column.name == naming.normalize_identifier(column_name)
      })
      |> option.from_result
    Error(_) -> None
  }
}

/// Search for a column across multiple tables, returning the column and the
/// table name where it was found.
pub fn find_column_in_tables(
  catalog: model.Catalog,
  table_names: List(String),
  column_name: String,
) -> Option(#(String, model.Column)) {
  list.find_map(table_names, fn(name) {
    case find_column(catalog, name, column_name) {
      Some(col) -> Ok(#(name, col))
      None -> Error(Nil)
    }
  })
  |> option.from_result
}

pub fn split_csv(text: String) -> List(String) {
  split_csv_paren_aware(text, 0, [], [])
  |> list.map(string.trim)
  |> list.filter(fn(entry) { entry != "" })
}

fn split_csv_paren_aware(
  remaining: String,
  depth: Int,
  current_rev: List(String),
  acc: List(String),
) -> List(String) {
  case string.pop_grapheme(remaining) {
    Error(_) -> {
      let current = current_rev |> list.reverse |> string.concat |> string.trim
      case current {
        "" -> list.reverse(acc)
        _ -> list.reverse([current, ..acc])
      }
    }
    Ok(#(grapheme, rest)) ->
      case grapheme {
        "(" ->
          split_csv_paren_aware(rest, depth + 1, [grapheme, ..current_rev], acc)
        ")" -> {
          let new_depth = case depth > 0 {
            True -> depth - 1
            False -> 0
          }
          split_csv_paren_aware(rest, new_depth, [grapheme, ..current_rev], acc)
        }
        "," ->
          case depth == 0 {
            True -> {
              let current =
                current_rev |> list.reverse |> string.concat |> string.trim
              split_csv_paren_aware(rest, depth, [], [current, ..acc])
            }
            False ->
              split_csv_paren_aware(rest, depth, [grapheme, ..current_rev], acc)
          }
        _ -> split_csv_paren_aware(rest, depth, [grapheme, ..current_rev], acc)
      }
  }
}
