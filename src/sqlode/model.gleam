import gleam/list
import gleam/option.{type Option}
import gleam/string
import sqlode/runtime

pub type Engine {
  PostgreSQL
  MySQL
  SQLite
}

pub fn parse_engine(value: String) -> Result(Engine, String) {
  case value {
    "postgresql" -> Ok(PostgreSQL)
    "mysql" -> Ok(MySQL)
    "sqlite" -> Ok(SQLite)
    _ -> Error("must be one of: postgresql, mysql, sqlite")
  }
}

pub fn engine_to_string(engine: Engine) -> String {
  case engine {
    PostgreSQL -> "postgresql"
    MySQL -> "mysql"
    SQLite -> "sqlite"
  }
}

pub type Runtime {
  Raw
  Native
}

pub type TypeMapping {
  StringMapping
  RichMapping
  StrongMapping
}

pub fn parse_type_mapping(value: String) -> Result(TypeMapping, String) {
  case value {
    "string" -> Ok(StringMapping)
    "rich" -> Ok(RichMapping)
    "strong" -> Ok(StrongMapping)
    _ -> Error("must be one of: string, rich, strong")
  }
}

pub fn type_mapping_to_string(mapping: TypeMapping) -> String {
  case mapping {
    StringMapping -> "string"
    RichMapping -> "rich"
    StrongMapping -> "strong"
  }
}

pub fn parse_runtime(value: String) -> Result(Runtime, String) {
  case value {
    "raw" -> Ok(Raw)
    "based" ->
      Error("\"based\" is not yet supported; use \"raw\" or \"native\" instead")
    "native" -> Ok(Native)
    _ -> Error("must be one of: raw, native")
  }
}

pub fn runtime_to_string(runtime: Runtime) -> String {
  case runtime {
    Raw -> "raw"
    Native -> "native"
  }
}

pub type TypeOverride {
  DbTypeOverride(db_type: String, gleam_type: String, nullable: Option(Bool))
  ColumnOverride(table: String, column: String, gleam_type: String)
}

pub type ColumnRename {
  ColumnRename(table: String, column: String, rename_to: String)
}

pub type Overrides {
  Overrides(
    type_overrides: List(TypeOverride),
    column_renames: List(ColumnRename),
  )
}

pub fn empty_overrides() -> Overrides {
  Overrides(type_overrides: [], column_renames: [])
}

pub type GleamOutput {
  GleamOutput(
    out: String,
    runtime: Runtime,
    type_mapping: TypeMapping,
    emit_sql_as_comment: Bool,
    emit_exact_table_names: Bool,
  )
}

pub type SqlBlock {
  SqlBlock(
    name: Option(String),
    engine: Engine,
    schema: List(String),
    queries: List(String),
    gleam: GleamOutput,
    overrides: Overrides,
  )
}

pub type Config {
  Config(version: Int, sql: List(SqlBlock))
}

pub fn is_result_command(command: runtime.QueryCommand) -> Bool {
  case command {
    runtime.QueryOne
    | runtime.QueryMany
    | runtime.QueryBatchOne
    | runtime.QueryBatchMany -> True
    _ -> False
  }
}

pub fn parse_query_command(
  value: String,
) -> Result(runtime.QueryCommand, String) {
  case value {
    ":one" -> Ok(runtime.QueryOne)
    ":many" -> Ok(runtime.QueryMany)
    ":exec" -> Ok(runtime.QueryExec)
    ":execresult" -> Ok(runtime.QueryExecResult)
    ":execrows" -> Ok(runtime.QueryExecRows)
    ":execlastid" -> Ok(runtime.QueryExecLastId)
    ":batchone" -> Ok(runtime.QueryBatchOne)
    ":batchmany" -> Ok(runtime.QueryBatchMany)
    ":batchexec" -> Ok(runtime.QueryBatchExec)
    ":copyfrom" -> Ok(runtime.QueryCopyFrom)
    _ ->
      Error(
        "must be one of: :one, :many, :exec, :execresult, :execrows, :execlastid, :batchone, :batchmany, :batchexec, :copyfrom",
      )
  }
}

pub fn query_command_to_string(command: runtime.QueryCommand) -> String {
  case command {
    runtime.QueryOne -> "QueryOne"
    runtime.QueryMany -> "QueryMany"
    runtime.QueryExec -> "QueryExec"
    runtime.QueryExecResult -> "QueryExecResult"
    runtime.QueryExecRows -> "QueryExecRows"
    runtime.QueryExecLastId -> "QueryExecLastId"
    runtime.QueryBatchOne -> "QueryBatchOne"
    runtime.QueryBatchMany -> "QueryBatchMany"
    runtime.QueryBatchExec -> "QueryBatchExec"
    runtime.QueryCopyFrom -> "QueryCopyFrom"
  }
}

pub type Macro {
  MacroArg(index: Int, name: String)
  MacroNarg(index: Int, name: String)
  MacroSlice(index: Int, name: String)
}

pub type ParsedQuery {
  ParsedQuery(
    name: String,
    function_name: String,
    command: runtime.QueryCommand,
    sql: String,
    source_path: String,
    param_count: Int,
    macros: List(Macro),
  )
}

pub type ScalarType {
  IntType
  FloatType
  BoolType
  StringType
  BytesType
  DateTimeType
  DateType
  TimeType
  UuidType
  JsonType
  EnumType(name: String)
  CustomType(
    name: String,
    module: option.Option(String),
    underlying: ScalarType,
  )
  ArrayType(element: ScalarType)
}

pub type EnumDef {
  EnumDef(name: String, values: List(String))
}

/// Parse a SQL type name into a ScalarType by normalizing the type token
/// (lowercasing, stripping modifiers and array markers, collapsing whitespace)
/// and matching the base name against a fixed table of built-ins.
///
/// Used by both schema parsing (CREATE TABLE column types) and query analysis
/// (PostgreSQL type casts like `$1::int`). Returns Error(Nil) for unrecognized
/// types so callers can surface the original text in a precise diagnostic
/// instead of guessing.
pub fn parse_sql_type(type_text: String) -> Result(ScalarType, Nil) {
  let normalized = normalize_type_text(type_text)
  case classify_normalized_base(normalized.base) {
    Ok(element_type) ->
      case normalized.is_array {
        True -> Ok(ArrayType(element_type))
        False -> Ok(element_type)
      }
    Error(Nil) -> Error(Nil)
  }
}

/// Classify by exact compound name first (e.g. "timestamp with time zone"),
/// then fall back to the first whitespace-separated token so trailing
/// garbage from unsupported column clauses (GENERATED, PARTITION BY) does
/// not block recognition of the primary type keyword.
fn classify_normalized_base(base: String) -> Result(ScalarType, Nil) {
  case classify_builtin_type(base) {
    Ok(t) -> Ok(t)
    Error(Nil) ->
      case string.split_once(base, " ") {
        Ok(#(first_word, _)) -> classify_builtin_type(first_word)
        Error(Nil) -> Error(Nil)
      }
  }
}

type NormalizedType {
  NormalizedType(base: String, is_array: Bool)
}

fn normalize_type_text(type_text: String) -> NormalizedType {
  let lowered =
    type_text
    |> string.lowercase
    |> string.trim
  let #(without_array, is_array) = strip_array_suffix(lowered, False)
  let without_modifier = strip_modifier(without_array)
  let base =
    without_modifier
    |> collapse_whitespace
    |> string.trim
  NormalizedType(base:, is_array:)
}

fn strip_array_suffix(text: String, seen: Bool) -> #(String, Bool) {
  let trimmed = string.trim_end(text)
  case string.ends_with(trimmed, "[]") {
    True -> strip_array_suffix(string.drop_end(trimmed, 2), True)
    False ->
      case string.ends_with(trimmed, " array") {
        True -> strip_array_suffix(string.drop_end(trimmed, 6), True)
        False -> #(trimmed, seen)
      }
  }
}

fn strip_modifier(text: String) -> String {
  // Drop from the first "(" or ")" so both modifiers like "numeric(10,2)"
  // and trailing fragments from surrounding SQL (e.g. a PARTITION BY
  // clause that leaked into the column's type tokens) are discarded
  // before classification.
  let after_open = case string.split_once(text, "(") {
    Ok(#(head, _)) -> head
    Error(Nil) -> text
  }
  case string.split_once(after_open, ")") {
    Ok(#(head, _)) -> head
    Error(Nil) -> after_open
  }
}

fn collapse_whitespace(text: String) -> String {
  text
  |> string.split(" ")
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
}

fn classify_builtin_type(base: String) -> Result(ScalarType, Nil) {
  case base {
    "int"
    | "int2"
    | "int4"
    | "int8"
    | "integer"
    | "smallint"
    | "bigint"
    | "mediumint"
    | "tinyint"
    | "serial"
    | "serial2"
    | "serial4"
    | "serial8"
    | "smallserial"
    | "bigserial"
    | "year" -> Ok(IntType)

    "float"
    | "float4"
    | "float8"
    | "real"
    | "double"
    | "double precision"
    | "numeric"
    | "decimal"
    | "dec"
    | "money"
    | "smallmoney" -> Ok(FloatType)

    "bool" | "boolean" -> Ok(BoolType)

    "bytea"
    | "blob"
    | "longblob"
    | "mediumblob"
    | "tinyblob"
    | "binary"
    | "varbinary" -> Ok(BytesType)

    "uuid" | "uniqueidentifier" -> Ok(UuidType)

    "json" | "jsonb" -> Ok(JsonType)

    "timestamp"
    | "timestamptz"
    | "timestamp with time zone"
    | "timestamp without time zone"
    | "datetime"
    | "datetime2" -> Ok(DateTimeType)

    "date" -> Ok(DateType)

    "time"
    | "timetz"
    | "time with time zone"
    | "time without time zone"
    | "interval" -> Ok(TimeType)

    "text"
    | "char"
    | "character"
    | "character varying"
    | "varchar"
    | "bpchar"
    | "nchar"
    | "nvarchar"
    | "clob"
    | "nclob"
    | "longtext"
    | "mediumtext"
    | "tinytext"
    | "string"
    | "name"
    | "citext"
    | "inet"
    | "cidr"
    | "macaddr"
    | "macaddr8"
    | "tsvector"
    | "tsquery"
    | "point"
    | "line"
    | "lseg"
    | "box"
    | "path"
    | "polygon"
    | "circle"
    | "xml"
    | "bit"
    | "bit varying"
    | "varbit" -> Ok(StringType)

    _ -> Error(Nil)
  }
}

pub type Column {
  Column(name: String, scalar_type: ScalarType, nullable: Bool)
}

pub type Table {
  Table(name: String, columns: List(Column))
}

pub type Catalog {
  Catalog(tables: List(Table), enums: List(EnumDef))
}

pub type QueryParam {
  QueryParam(
    index: Int,
    field_name: String,
    scalar_type: ScalarType,
    nullable: Bool,
    is_list: Bool,
  )
}

pub type ResultColumn {
  ResultColumn(
    name: String,
    scalar_type: ScalarType,
    nullable: Bool,
    source_table: Option(String),
  )
}

pub type EmbeddedColumn {
  EmbeddedColumn(name: String, table_name: String, columns: List(Column))
}

pub type ResultItem {
  ScalarResult(ResultColumn)
  EmbeddedResult(EmbeddedColumn)
}

pub type AnalyzedQuery {
  AnalyzedQuery(
    base: ParsedQuery,
    params: List(QueryParam),
    result_columns: List(ResultItem),
  )
}
