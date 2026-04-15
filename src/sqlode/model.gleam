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

pub fn is_result_command(command: QueryCommand) -> Bool {
  case command {
    One | Many | BatchOne | BatchMany -> True
    _ -> False
  }
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

pub type Macro {
  MacroArg(index: Int, name: String)
  MacroNarg(index: Int, name: String)
  MacroSlice(index: Int, name: String)
}

pub type ParsedQuery {
  ParsedQuery(
    name: String,
    function_name: String,
    command: QueryCommand,
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
  CustomType(name: String, underlying: ScalarType)
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

// --- ScalarType property table ---
// All leaf type properties are defined once here. Adding a new leaf type
// only requires adding one entry to this table instead of editing 6 functions.

type ScalarTypeInfo {
  ScalarTypeInfo(
    gleam_type: String,
    rich_type: option.Option(String),
    runtime_fn: String,
    db_name: String,
    value_fn: String,
    decoder: String,
    unwrap_fn: option.Option(String),
  )
}

fn scalar_type_info(scalar_type: ScalarType) -> option.Option(ScalarTypeInfo) {
  case scalar_type {
    IntType ->
      option.Some(ScalarTypeInfo(
        gleam_type: "Int",
        rich_type: option.None,
        runtime_fn: "runtime.int",
        db_name: "int",
        value_fn: "int",
        decoder: "decode.int",
        unwrap_fn: option.None,
      ))
    FloatType ->
      option.Some(ScalarTypeInfo(
        gleam_type: "Float",
        rich_type: option.None,
        runtime_fn: "runtime.float",
        db_name: "float",
        value_fn: "float",
        decoder: "decode.float",
        unwrap_fn: option.None,
      ))
    BoolType ->
      option.Some(ScalarTypeInfo(
        gleam_type: "Bool",
        rich_type: option.None,
        runtime_fn: "runtime.bool",
        db_name: "bool",
        value_fn: "bool",
        decoder: "decode.bool",
        unwrap_fn: option.None,
      ))
    StringType ->
      option.Some(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.None,
        runtime_fn: "runtime.string",
        db_name: "string",
        value_fn: "text",
        decoder: "decode.string",
        unwrap_fn: option.None,
      ))
    BytesType ->
      option.Some(ScalarTypeInfo(
        gleam_type: "BitArray",
        rich_type: option.None,
        runtime_fn: "runtime.bytes",
        db_name: "bytes",
        value_fn: "bytea",
        decoder: "decode.bit_array",
        unwrap_fn: option.None,
      ))
    DateTimeType ->
      option.Some(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlTimestamp"),
        runtime_fn: "runtime.string",
        db_name: "datetime",
        value_fn: "text",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_timestamp_to_string"),
      ))
    DateType ->
      option.Some(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlDate"),
        runtime_fn: "runtime.string",
        db_name: "date",
        value_fn: "text",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_date_to_string"),
      ))
    TimeType ->
      option.Some(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlTime"),
        runtime_fn: "runtime.string",
        db_name: "time",
        value_fn: "text",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_time_to_string"),
      ))
    UuidType ->
      option.Some(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlUuid"),
        runtime_fn: "runtime.string",
        db_name: "uuid",
        value_fn: "text",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_uuid_to_string"),
      ))
    JsonType ->
      option.Some(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlJson"),
        runtime_fn: "runtime.string",
        db_name: "json",
        value_fn: "text",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_json_to_string"),
      ))
    // EnumType, CustomType, ArrayType need special handling
    _ -> option.None
  }
}

// --- Public API (delegates to table for leaf types) ---

pub fn scalar_type_to_gleam_type(
  scalar_type: ScalarType,
  type_mapping: TypeMapping,
) -> String {
  case scalar_type_info(scalar_type) {
    option.Some(info) ->
      case type_mapping, info.rich_type {
        RichMapping, option.Some(rich) | StrongMapping, option.Some(rich) ->
          rich
        _, _ -> info.gleam_type
      }
    option.None ->
      case scalar_type {
        EnumType(name) -> enum_type_name(name)
        CustomType(name, _) -> name
        ArrayType(element) ->
          "List(" <> scalar_type_to_gleam_type(element, type_mapping) <> ")"
        _ -> "String"
      }
  }
}

pub fn is_rich_type(scalar_type: ScalarType) -> Bool {
  case scalar_type_info(scalar_type) {
    option.Some(info) -> option.is_some(info.rich_type)
    option.None -> False
  }
}

pub fn strong_type_unwrap_fn(scalar_type: ScalarType) -> option.Option(String) {
  case scalar_type_info(scalar_type) {
    option.Some(info) -> info.unwrap_fn
    option.None -> option.None
  }
}

pub fn scalar_type_to_runtime_function(scalar_type: ScalarType) -> String {
  case scalar_type_info(scalar_type) {
    option.Some(info) -> info.runtime_fn
    option.None ->
      case scalar_type {
        EnumType(_) -> "runtime.string"
        CustomType(_, underlying) -> scalar_type_to_runtime_function(underlying)
        ArrayType(element) -> scalar_type_to_runtime_function(element)
        _ -> "runtime.string"
      }
  }
}

pub fn scalar_type_to_db_name(scalar_type: ScalarType) -> String {
  case scalar_type_info(scalar_type) {
    option.Some(info) -> info.db_name
    option.None ->
      case scalar_type {
        EnumType(name) -> name
        CustomType(_, underlying) -> scalar_type_to_db_name(underlying)
        ArrayType(element) -> scalar_type_to_db_name(element) <> "[]"
        _ -> "string"
      }
  }
}

pub fn scalar_type_to_value_function(
  engine: Engine,
  scalar_type: ScalarType,
) -> String {
  case scalar_type_info(scalar_type) {
    option.Some(info) ->
      case scalar_type {
        BytesType ->
          case engine {
            PostgreSQL -> "bytea"
            SQLite | MySQL -> "blob"
          }
        _ -> info.value_fn
      }
    option.None ->
      case scalar_type {
        EnumType(_) -> "text"
        CustomType(_, underlying) ->
          scalar_type_to_value_function(engine, underlying)
        ArrayType(element) ->
          "array(pog." <> scalar_type_to_value_function(engine, element) <> ")"
        _ -> "text"
      }
  }
}

pub fn scalar_type_to_decoder(engine: Engine, scalar_type: ScalarType) -> String {
  case scalar_type_info(scalar_type) {
    option.Some(info) ->
      case scalar_type {
        BoolType ->
          case engine {
            SQLite ->
              "decode.then(decode.int, fn(v) { decode.success(v != 0) })"
            PostgreSQL | MySQL -> "decode.bool"
          }
        _ -> info.decoder
      }
    option.None ->
      case scalar_type {
        EnumType(_) -> "decode.string"
        CustomType(_, underlying) -> scalar_type_to_decoder(engine, underlying)
        ArrayType(element) ->
          "decode.list(" <> scalar_type_to_decoder(engine, element) <> ")"
        _ -> "decode.string"
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
