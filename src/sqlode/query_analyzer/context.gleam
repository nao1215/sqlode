import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import sqlode/model
import sqlode/naming

pub type AnalysisError {
  TableNotFound(query_name: String, table_name: String)
  ColumnNotFound(query_name: String, table_name: String, column_name: String)
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
  }
}

pub type AnalyzerContext {
  AnalyzerContext(
    naming: naming.NamingContext,
    insert_re: regexp.Regexp,
    equality_re: regexp.Regexp,
    postgresql_placeholder_re: regexp.Regexp,
    mysql_placeholder_re: regexp.Regexp,
    sqlite_placeholder_re: regexp.Regexp,
    whitespace_re: regexp.Regexp,
    table_from_re: regexp.Regexp,
    table_into_re: regexp.Regexp,
    table_update_re: regexp.Regexp,
    table_delete_re: regexp.Regexp,
    cte_re: regexp.Regexp,
    returning_re: regexp.Regexp,
    join_re: regexp.Regexp,
    select_columns_re: regexp.Regexp,
    type_cast_re: regexp.Regexp,
    in_clause_re: regexp.Regexp,
  )
}

pub fn new(naming_ctx: naming.NamingContext) -> AnalyzerContext {
  let assert Ok(insert_re) =
    regexp.from_string(
      "insert\\s+into\\s+([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(([^)]*)\\)\\s*values\\s*\\(([^)]*)\\)",
    )
  let assert Ok(equality_re) =
    regexp.from_string(
      "([a-zA-Z_][a-zA-Z0-9_.]*)\\s*=\\s*(\\$[0-9]+|\\?|:[A-Za-z_][A-Za-z0-9_]*|@[A-Za-z_][A-Za-z0-9_]*|\\$[A-Za-z_][A-Za-z0-9_]*)",
    )
  let assert Ok(postgresql_placeholder_re) = regexp.from_string("(\\$[0-9]+)")
  let assert Ok(mysql_placeholder_re) = regexp.from_string("(\\?)")
  let assert Ok(sqlite_placeholder_re) =
    regexp.from_string(
      "(\\?[0-9]+|\\?|:[A-Za-z_][A-Za-z0-9_]*|@[A-Za-z_][A-Za-z0-9_]*|\\$[A-Za-z_][A-Za-z0-9_]*)",
    )
  let assert Ok(whitespace_re) = regexp.from_string("\\s+")
  let assert Ok(table_from_re) =
    regexp.from_string("from\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
  let assert Ok(table_into_re) =
    regexp.from_string("into\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
  let assert Ok(table_update_re) =
    regexp.from_string("update\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
  let assert Ok(table_delete_re) =
    regexp.from_string("delete\\s+from\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
  let assert Ok(cte_re) =
    regexp.from_string("^with\\s+.+\\)\\s+(select|insert|update|delete)\\s")
  let assert Ok(returning_re) =
    regexp.from_string("returning\\s+(.+?)\\s*;?\\s*$")
  let assert Ok(join_re) =
    regexp.from_string("join\\s+([a-zA-Z_][a-zA-Z0-9_]*)\\s")
  let assert Ok(select_columns_re) =
    regexp.from_string("select\\s+(.+?)\\s+from\\s")
  let assert Ok(type_cast_re) =
    regexp.from_string("(\\$[0-9]+)::[a-zA-Z_][a-zA-Z0-9_]*")
  let assert Ok(in_clause_re) =
    regexp.from_string(
      "([a-zA-Z_][a-zA-Z0-9_.]*)\\s+in\\s*\\(\\s*(\\$[0-9]+|\\?[0-9]*|:[A-Za-z_][A-Za-z0-9_]*|@[A-Za-z_][A-Za-z0-9_]*|\\$[A-Za-z_][A-Za-z0-9_]*)\\s*\\)",
    )

  AnalyzerContext(
    naming: naming_ctx,
    insert_re:,
    equality_re:,
    postgresql_placeholder_re:,
    mysql_placeholder_re:,
    sqlite_placeholder_re:,
    whitespace_re:,
    table_from_re:,
    table_into_re:,
    table_update_re:,
    table_delete_re:,
    cte_re:,
    returning_re:,
    join_re:,
    select_columns_re:,
    type_cast_re:,
    in_clause_re:,
  )
}

pub fn normalize_sql(ctx: AnalyzerContext, sql: String) -> String {
  let lowered = string.lowercase(sql)
  regexp.replace(ctx.whitespace_re, lowered, " ")
  |> string.trim
}

pub fn primary_table_name(ctx: AnalyzerContext, sql: String) -> Option(String) {
  let regexes = [
    ctx.table_from_re,
    ctx.table_into_re,
    ctx.table_update_re,
    ctx.table_delete_re,
  ]
  find_first_match(regexes, sql)
}

fn find_first_match(regexes: List(regexp.Regexp), sql: String) -> Option(String) {
  list.find_map(regexes, fn(re) {
    case regexp.scan(re, sql) {
      [match, ..] ->
        case match.submatches {
          [Some(name)] -> Ok(name)
          _ -> Error(Nil)
        }
      [] -> Error(Nil)
    }
  })
  |> option.from_result
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

pub fn split_csv(text: String) -> List(String) {
  text
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(entry) { entry != "" })
}
