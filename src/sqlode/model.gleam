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

/// Parse a SQL type name into a ScalarType using substring matching.
/// Used by both schema parsing (CREATE TABLE column types) and
/// query analysis (PostgreSQL type casts like `$1::int`).
/// Returns Error(Nil) for unrecognized types.
pub fn parse_sql_type(type_text: String) -> Result(ScalarType, Nil) {
  let lowered = string.lowercase(type_text)
  // Detect PostgreSQL array syntax: TYPE[] or TYPE ARRAY
  let #(base_type_text, is_array) = case string.ends_with(lowered, "[]") {
    True -> #(string.drop_end(lowered, 2), True)
    False ->
      case string.ends_with(lowered, " array") {
        True -> #(string.drop_end(lowered, 6), True)
        False -> #(lowered, False)
      }
  }
  // Order matters: check more specific patterns before general ones
  // (e.g. "timestamp"/"datetime" before "time"/"date", "jsonb" before "json")
  // Order matters: more specific patterns must come before general ones.
  // "interval" before "int" (interval contains "int" as substring).
  // "point" before "int" (point contains "int" as substring).
  // "timestamp"/"datetime" before "time"/"date".
  // "jsonb" before "json".
  let type_rules = [
    #(["double", "real", "float", "numeric", "decimal", "money"], FloatType),
    #(["bool"], BoolType),
    #(["bytea", "blob", "binary"], BytesType),
    #(["uuid"], UuidType),
    #(["jsonb", "json"], JsonType),
    #(["timestamp", "datetime"], DateTimeType),
    #(["date"], DateType),
    #(["timetz", "interval"], TimeType),
    #(
      [
        "citext", "inet", "cidr", "macaddr", "tsvector", "tsquery", "point",
        "line", "lseg", "box", "path", "polygon", "circle", "xml", "bit",
      ],
      StringType,
    ),
    #(["int", "serial"], IntType),
    #(["time"], TimeType),
    #(["text", "char", "clob", "name", "string"], StringType),
  ]
  case find_matching_type(base_type_text, type_rules) {
    Ok(element_type) ->
      case is_array {
        True -> Ok(ArrayType(element_type))
        False -> Ok(element_type)
      }
    Error(Nil) -> Error(Nil)
  }
}

fn find_matching_type(
  lowered: String,
  rules: List(#(List(String), ScalarType)),
) -> Result(ScalarType, Nil) {
  case rules {
    [] -> Error(Nil)
    [#(patterns, scalar_type), ..rest] ->
      case list.any(patterns, fn(p) { string.contains(lowered, p) }) {
        True -> Ok(scalar_type)
        False -> find_matching_type(lowered, rest)
      }
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
  EmbeddedColumn(name: String, table_name: String, columns: List(Column))
}

pub type AnalyzedQuery {
  AnalyzedQuery(
    base: ParsedQuery,
    params: List(QueryParam),
    result_columns: List(ResultColumn),
  )
}
