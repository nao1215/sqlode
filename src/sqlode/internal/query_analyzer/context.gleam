import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sqlode/internal/model
import sqlode/internal/naming

pub type AnalysisError {
  TableNotFound(query_name: String, table_name: String)
  ColumnNotFound(query_name: String, table_name: String, column_name: String)
  ParameterTypeNotInferred(query_name: String, param_index: Int)
  ParameterTypeConflict(
    query_name: String,
    param_index: Int,
    type_a: model.ScalarType,
    type_b: model.ScalarType,
  )
  UnrecognizedCastType(query_name: String, param_index: Int, cast_type: String)
  CompoundColumnCountMismatch(
    query_name: String,
    first_count: Int,
    branch_count: Int,
  )
  UnsupportedExpression(query_name: String, expression: String)
  AmbiguousColumnName(
    query_name: String,
    column_name: String,
    matching_tables: List(String),
  )
}

/// Render an `AnalysisError` as a user-facing message tailored to
/// `engine`. Placeholder references and cast-syntax hints both
/// follow the configured engine's dialect — `$1` / `$1::int` for
/// PostgreSQL, `?1` / `CAST(? AS INTEGER)` for SQLite, `?1` /
/// `CAST(? AS SIGNED)` for MySQL — so the suggested fix in the
/// error message is something the user can paste into their query
/// without further translation. (#473)
pub fn analysis_error_to_string(
  error: AnalysisError,
  engine: model.Engine,
) -> String {
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
      <> "\": could not infer type for parameter "
      <> placeholder_label(engine, param_index)
      <> ". "
      <> cast_hint(engine, param_index)
    UnrecognizedCastType(query_name:, param_index:, cast_type:) ->
      "Query \""
      <> query_name
      <> "\": unrecognized cast type \""
      <> cast_type
      <> "\" for parameter "
      <> placeholder_label(engine, param_index)
    CompoundColumnCountMismatch(query_name:, first_count:, branch_count:) ->
      "Query \""
      <> query_name
      <> "\": compound query branch has "
      <> int.to_string(branch_count)
      <> " columns, but the first branch has "
      <> int.to_string(first_count)
    ParameterTypeConflict(query_name:, param_index:, type_a:, type_b:) ->
      "Query \""
      <> query_name
      <> "\": parameter "
      <> placeholder_label(engine, param_index)
      <> " has conflicting inferred types \""
      <> scalar_type_label(type_a)
      <> "\" and \""
      <> scalar_type_label(type_b)
      <> "\". Use a type cast to resolve the ambiguity"
    UnsupportedExpression(query_name:, expression:) ->
      "Query \""
      <> query_name
      <> "\": unsupported expression \""
      <> expression
      <> "\", cannot infer result type. Use CAST to specify the type explicitly"
    AmbiguousColumnName(query_name:, column_name:, matching_tables:) ->
      "Query \""
      <> query_name
      <> "\": column \""
      <> column_name
      <> "\" is ambiguous — found in tables: "
      <> string.join(matching_tables, ", ")
      <> ". Use a table qualifier (e.g. table.column) to resolve the ambiguity"
  }
}

/// Engine-specific user-facing placeholder reference, e.g. `$1` for
/// PostgreSQL, `?1` for SQLite / MySQL. The 1-based positional form
/// `?N` is used for the latter two so the message points at a
/// specific parameter even though MySQL's wire-level placeholder is
/// the bare `?`. SQLite accepts `?N` natively.
fn placeholder_label(engine: model.Engine, idx: Int) -> String {
  case engine {
    model.PostgreSQL -> "$" <> int.to_string(idx)
    model.SQLite -> "?" <> int.to_string(idx)
    model.MySQL -> "?" <> int.to_string(idx)
  }
}

/// Engine-specific cast-syntax hint. The placeholder shown inside
/// the hint matches the engine's dialect so the user can copy the
/// suggestion verbatim into their query.
fn cast_hint(engine: model.Engine, idx: Int) -> String {
  case engine {
    model.PostgreSQL ->
      "Use a type cast (e.g. $"
      <> int.to_string(idx)
      <> "::int) to specify the type"
    model.SQLite -> "Use CAST(? AS INTEGER) to specify the type"
    model.MySQL -> "Use CAST(? AS SIGNED) to specify the type"
  }
}

fn scalar_type_label(t: model.ScalarType) -> String {
  case t {
    model.IntType -> "Int"
    model.FloatType -> "Float"
    model.BoolType -> "Bool"
    model.StringType -> "String"
    model.BytesType -> "BitArray"
    model.DateTimeType -> "DateTime"
    model.DateType -> "Date"
    model.TimeType -> "Time"
    model.UuidType -> "Uuid"
    model.JsonType -> "Json"
    model.DecimalType -> "Decimal"
    model.EnumType(name) -> "Enum(" <> name <> ")"
    model.SetType(name) -> "Set(" <> name <> ")"
    model.CustomType(name, ..) -> name
    model.ArrayType(element) -> "List(" <> scalar_type_label(element) <> ")"
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
///
/// Returns `Error(matching_table_names)` when the column exists in more than
/// one of the given tables (ambiguous reference).
pub fn find_column_in_tables(
  catalog: model.Catalog,
  table_names: List(String),
  column_name: String,
) -> Result(Option(#(String, model.Column)), List(String)) {
  let matches =
    list.filter_map(table_names, fn(name) {
      case find_column(catalog, name, column_name) {
        Some(col) -> Ok(#(name, col))
        None -> Error(Nil)
      }
    })
  case matches {
    [] -> Ok(None)
    [single] -> Ok(Some(single))
    _ -> Error(list.map(matches, fn(m) { m.0 }))
  }
}
