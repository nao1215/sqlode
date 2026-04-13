import gleam/option.{type Option}

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
  Based
  Native
}

pub fn parse_runtime(value: String) -> Result(Runtime, String) {
  case value {
    "raw" -> Ok(Raw)
    "based" -> Ok(Based)
    "native" -> Ok(Native)
    _ -> Error("must be one of: raw, based, native")
  }
}

pub fn runtime_to_string(runtime: Runtime) -> String {
  case runtime {
    Raw -> "raw"
    Based -> "based"
    Native -> "native"
  }
}

pub type TypeOverride {
  TypeOverride(db_type: String, gleam_type: String)
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
  GleamOutput(package: String, out: String, runtime: Runtime)
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
}

pub fn parse_query_command(value: String) -> Result(QueryCommand, String) {
  case value {
    ":one" -> Ok(One)
    ":many" -> Ok(Many)
    ":exec" -> Ok(Exec)
    ":execresult" -> Ok(ExecResult)
    ":execrows" -> Ok(ExecRows)
    ":execlastid" -> Ok(ExecLastId)
    _ ->
      Error(
        "must be one of: :one, :many, :exec, :execresult, :execrows, :execlastid",
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
}

pub type EnumDef {
  EnumDef(name: String, values: List(String))
}

pub fn scalar_type_to_gleam_type(scalar_type: ScalarType) -> String {
  case scalar_type {
    IntType -> "Int"
    FloatType -> "Float"
    BoolType -> "Bool"
    StringType -> "String"
    BytesType -> "BitArray"
    DateTimeType | DateType | TimeType | UuidType | JsonType -> "String"
    EnumType(_) -> "String"
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
  ResultColumn(name: String, scalar_type: ScalarType, nullable: Bool)
}

pub type AnalyzedQuery {
  AnalyzedQuery(
    base: ParsedQuery,
    params: List(QueryParam),
    result_columns: List(ResultColumn),
  )
}
