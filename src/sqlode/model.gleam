import gleam/list
import gleam/option.{type Option}
import gleam/string

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
}

pub fn parse_type_mapping(value: String) -> Result(TypeMapping, String) {
  case value {
    "string" -> Ok(StringMapping)
    "rich" -> Ok(RichMapping)
    _ -> Error("must be one of: string, rich")
  }
}

pub fn type_mapping_to_string(mapping: TypeMapping) -> String {
  case mapping {
    StringMapping -> "string"
    RichMapping -> "rich"
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
    package: String,
    out: String,
    runtime: Runtime,
    type_mapping: TypeMapping,
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

pub type QueryCommand {
  One
  Many
  Exec
  ExecResult
  ExecRows
  ExecLastId
  BatchOne
  BatchMany
  BatchExec
  CopyFrom
}

pub fn parse_query_command(value: String) -> Result(QueryCommand, String) {
  case value {
    ":one" -> Ok(One)
    ":many" -> Ok(Many)
    ":exec" -> Ok(Exec)
    ":execresult" -> Ok(ExecResult)
    ":execrows" -> Ok(ExecRows)
    ":execlastid" -> Ok(ExecLastId)
    ":batchone" -> Ok(BatchOne)
    ":batchmany" -> Ok(BatchMany)
    ":batchexec" -> Ok(BatchExec)
    ":copyfrom" -> Ok(CopyFrom)
    _ ->
      Error(
        "must be one of: :one, :many, :exec, :execresult, :execrows, :execlastid, :batchone, :batchmany, :batchexec, :copyfrom",
      )
  }
}

pub fn query_command_to_variant(command: QueryCommand) -> String {
  case command {
    One -> "QueryOne"
    Many -> "QueryMany"
    Exec -> "QueryExec"
    ExecResult -> "QueryExecResult"
    ExecRows -> "QueryExecRows"
    ExecLastId -> "QueryExecLastId"
    BatchOne -> "QueryBatchOne"
    BatchMany -> "QueryBatchMany"
    BatchExec -> "QueryBatchExec"
    CopyFrom -> "QueryCopyFrom"
  }
}

pub type SqlcMacro {
  SqlcArg(index: Int, name: String)
  SqlcNarg(index: Int, name: String)
  SqlcSlice(index: Int, name: String)
}

pub type ParsedQuery {
  ParsedQuery(
    name: String,
    function_name: String,
    command: QueryCommand,
    sql: String,
    source_path: String,
    param_count: Int,
    macros: List(SqlcMacro),
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
  CustomType(name: String, underlying: ScalarType)
}

pub type EnumDef {
  EnumDef(name: String, values: List(String))
}

pub fn scalar_type_to_gleam_type(
  scalar_type: ScalarType,
  type_mapping: TypeMapping,
) -> String {
  case scalar_type {
    IntType -> "Int"
    FloatType -> "Float"
    BoolType -> "Bool"
    StringType -> "String"
    BytesType -> "BitArray"
    DateTimeType ->
      case type_mapping {
        RichMapping -> "SqlTimestamp"
        StringMapping -> "String"
      }
    DateType ->
      case type_mapping {
        RichMapping -> "SqlDate"
        StringMapping -> "String"
      }
    TimeType ->
      case type_mapping {
        RichMapping -> "SqlTime"
        StringMapping -> "String"
      }
    UuidType ->
      case type_mapping {
        RichMapping -> "SqlUuid"
        StringMapping -> "String"
      }
    JsonType ->
      case type_mapping {
        RichMapping -> "SqlJson"
        StringMapping -> "String"
      }
    EnumType(name) -> enum_type_name(name)
    CustomType(name, _) -> name
  }
}

/// Returns true if the given ScalarType produces a semantic alias under RichMapping.
pub fn is_rich_type(scalar_type: ScalarType) -> Bool {
  case scalar_type {
    DateTimeType | DateType | TimeType | UuidType | JsonType -> True
    _ -> False
  }
}

pub fn scalar_type_to_runtime_function(scalar_type: ScalarType) -> String {
  case scalar_type {
    IntType -> "runtime.int"
    FloatType -> "runtime.float"
    BoolType -> "runtime.bool"
    StringType -> "runtime.string"
    BytesType -> "runtime.bytes"
    DateTimeType | DateType | TimeType | UuidType | JsonType -> "runtime.string"
    EnumType(_) -> "runtime.string"
    CustomType(_, underlying) -> scalar_type_to_runtime_function(underlying)
  }
}

pub fn scalar_type_to_db_name(scalar_type: ScalarType) -> String {
  case scalar_type {
    IntType -> "int"
    FloatType -> "float"
    BoolType -> "bool"
    StringType -> "string"
    BytesType -> "bytes"
    DateTimeType -> "datetime"
    DateType -> "date"
    TimeType -> "time"
    UuidType -> "uuid"
    JsonType -> "json"
    EnumType(name) -> name
    CustomType(_, underlying) -> scalar_type_to_db_name(underlying)
  }
}

pub fn scalar_type_to_value_function(
  engine: Engine,
  scalar_type: ScalarType,
) -> String {
  case scalar_type {
    IntType -> "int"
    FloatType -> "float"
    BoolType -> "bool"
    StringType -> "text"
    BytesType ->
      case engine {
        PostgreSQL -> "bytea"
        SQLite | MySQL -> "blob"
      }
    DateTimeType | DateType | TimeType | UuidType | JsonType | EnumType(_) ->
      "text"
    CustomType(_, underlying) ->
      scalar_type_to_value_function(engine, underlying)
  }
}

pub fn scalar_type_to_decoder(engine: Engine, scalar_type: ScalarType) -> String {
  case scalar_type {
    IntType -> "decode.int"
    FloatType -> "decode.float"
    BoolType ->
      case engine {
        SQLite -> "decode.then(decode.int, fn(v) { decode.success(v != 0) })"
        PostgreSQL | MySQL -> "decode.bool"
      }
    StringType -> "decode.string"
    BytesType -> "decode.bit_array"
    DateTimeType | DateType | TimeType | UuidType | JsonType | EnumType(_) ->
      "decode.string"
    CustomType(_, underlying) -> scalar_type_to_decoder(engine, underlying)
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

pub fn enum_type_name(name: String) -> String {
  simple_pascal_case(name)
}

pub fn enum_value_name(value: String) -> String {
  simple_pascal_case(value)
}

pub fn enum_to_string_fn(name: String) -> String {
  string.lowercase(name) <> "_to_string"
}

pub fn enum_from_string_fn(name: String) -> String {
  string.lowercase(name) <> "_from_string"
}

fn simple_pascal_case(input: String) -> String {
  input
  |> string.split("_")
  |> list.map(fn(word) {
    case string.pop_grapheme(word) {
      Ok(#(first, rest)) -> string.uppercase(first) <> string.lowercase(rest)
      Error(_) -> word
    }
  })
  |> string.join("")
}
