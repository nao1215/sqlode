import gleam/list
import gleam/option
import gleam/result
import gleam/string
import sqlode/internal/char_utils
import sqlode/internal/model.{
  type Engine, type ScalarType, type TypeMapping, ArrayType, BoolType, BytesType,
  CustomType, DateTimeType, DateType, DecimalType, EnumType, FloatType, IntType,
  JsonType, MySQL, PostgreSQL, RichMapping, SQLite, SetType, StringType,
  StrongMapping, TimeType, UuidType,
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
    decoder: String,
    unwrap_fn: option.Option(String),
  )
}

type TypeResolution {
  LeafType(ScalarTypeInfo)
  EnumResolution(name: String)
  SetResolution(name: String)
  CustomResolution(
    name: String,
    module: option.Option(String),
    underlying: ScalarType,
  )
  ArrayResolution(element: ScalarType)
}

fn resolve_type(scalar_type: ScalarType) -> TypeResolution {
  case scalar_type {
    IntType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "Int",
        rich_type: option.None,
        runtime_fn: "runtime.int",
        db_name: "int",
        decoder: "decode.int",
        unwrap_fn: option.None,
      ))
    FloatType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "Float",
        rich_type: option.None,
        runtime_fn: "runtime.float",
        db_name: "float",
        decoder: "decode.float",
        unwrap_fn: option.None,
      ))
    BoolType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "Bool",
        rich_type: option.None,
        runtime_fn: "runtime.bool",
        db_name: "bool",
        decoder: "decode.bool",
        unwrap_fn: option.None,
      ))
    StringType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.None,
        runtime_fn: "runtime.string",
        db_name: "string",
        decoder: "decode.string",
        unwrap_fn: option.None,
      ))
    BytesType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "BitArray",
        rich_type: option.None,
        runtime_fn: "runtime.bytes",
        db_name: "bytes",
        decoder: "decode.bit_array",
        unwrap_fn: option.None,
      ))
    DateTimeType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlTimestamp"),
        runtime_fn: "runtime.string",
        db_name: "datetime",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_timestamp_to_string"),
      ))
    DateType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlDate"),
        runtime_fn: "runtime.string",
        db_name: "date",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_date_to_string"),
      ))
    TimeType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlTime"),
        runtime_fn: "runtime.string",
        db_name: "time",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_time_to_string"),
      ))
    UuidType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlUuid"),
        runtime_fn: "runtime.string",
        db_name: "uuid",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_uuid_to_string"),
      ))
    JsonType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlJson"),
        runtime_fn: "runtime.string",
        db_name: "json",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_json_to_string"),
      ))
    DecimalType ->
      LeafType(ScalarTypeInfo(
        gleam_type: "String",
        rich_type: option.Some("SqlDecimal"),
        runtime_fn: "runtime.string",
        db_name: "decimal",
        decoder: "decode.string",
        unwrap_fn: option.Some("sql_decimal_to_string"),
      ))
    EnumType(name) -> EnumResolution(name)
    SetType(name) -> SetResolution(name)
    CustomType(name, module, underlying, _codec) ->
      CustomResolution(name, module, underlying)
    ArrayType(element) -> ArrayResolution(element)
  }
}

// --- Public API (delegates to table for leaf types) ---

pub fn scalar_type_to_gleam_type(
  scalar_type: ScalarType,
  type_mapping: TypeMapping,
) -> String {
  case resolve_type(scalar_type) {
    LeafType(info) ->
      case type_mapping, info.rich_type {
        RichMapping, option.Some(rich) | StrongMapping, option.Some(rich) ->
          rich
        _, _ -> info.gleam_type
      }
    EnumResolution(name) -> enum_type_name(name)
    SetResolution(name) -> "List(" <> set_value_type_name(name) <> ")"
    CustomResolution(name, _, _) -> name
    ArrayResolution(element) ->
      "List(" <> scalar_type_to_gleam_type(element, type_mapping) <> ")"
  }
}

pub fn is_rich_type(scalar_type: ScalarType) -> Bool {
  case resolve_type(scalar_type) {
    LeafType(info) -> option.is_some(info.rich_type)
    EnumResolution(_)
    | SetResolution(_)
    | CustomResolution(_, _, _)
    | ArrayResolution(_) -> False
  }
}

pub fn strong_type_unwrap_fn(scalar_type: ScalarType) -> option.Option(String) {
  case resolve_type(scalar_type) {
    LeafType(info) -> info.unwrap_fn
    EnumResolution(_)
    | SetResolution(_)
    | CustomResolution(_, _, _)
    | ArrayResolution(_) -> option.None
  }
}

pub fn scalar_type_to_runtime_function(scalar_type: ScalarType) -> String {
  case resolve_type(scalar_type) {
    LeafType(info) -> info.runtime_fn
    EnumResolution(_) -> "runtime.string"
    SetResolution(_) -> "runtime.string"
    CustomResolution(_, _, underlying) ->
      scalar_type_to_runtime_function(underlying)
    ArrayResolution(element) -> scalar_type_to_runtime_function(element)
  }
}

pub fn scalar_type_to_db_name(scalar_type: ScalarType) -> String {
  case resolve_type(scalar_type) {
    LeafType(info) -> info.db_name
    EnumResolution(name) -> name
    SetResolution(name) -> name
    CustomResolution(_, _, underlying) -> scalar_type_to_db_name(underlying)
    ArrayResolution(element) -> scalar_type_to_db_name(element) <> "[]"
  }
}

pub fn scalar_type_to_decoder(
  engine: Engine,
  scalar_type: ScalarType,
) -> String {
  case resolve_type(scalar_type) {
    LeafType(info) ->
      case scalar_type {
        BoolType ->
          case engine {
            // SQLite stores booleans as 0/1 INTEGER; MySQL's TINYINT(1)
            // and BOOLEAN come back from the Erlang `mysql` driver as
            // 0/1 too, so they share the int → boolean adapter.
            SQLite | MySQL ->
              "decode.then(decode.int, fn(v) { decode.success(v != 0) })"
            PostgreSQL -> "decode.bool"
          }
        _ -> info.decoder
      }
    EnumResolution(_) -> "decode.string"
    SetResolution(_) -> "decode.string"
    CustomResolution(_, _, underlying) ->
      scalar_type_to_decoder(engine, underlying)
    ArrayResolution(element) ->
      "decode.list(" <> scalar_type_to_decoder(engine, element) <> ")"
  }
}

// --- Enum naming utilities ---

pub fn enum_type_name(name: String) -> String {
  simple_pascal_case(name)
}

pub fn enum_value_name(value: String) -> String {
  simple_pascal_case(value)
}

/// Why an enum value cannot become a Gleam constructor.
pub type EnumValueError {
  /// The value does not turn into a Gleam constructor name.
  UnnamableEnumValue(enum_name: String, value: String, variant: String)
  /// Two values turn into the same constructor name.
  CollidingEnumValues(
    enum_name: String,
    first: String,
    second: String,
    variant: String,
  )
}

/// Check that every value of every enum (and MySQL SET) turns into a
/// distinct Gleam constructor, so the generated module compiles.
pub fn validate_enum_values(
  enums: List(model.EnumDef),
) -> Result(Nil, EnumValueError) {
  list.try_each(enums, fn(enum_def) {
    list.try_fold(enum_def.values, [], fn(seen, value) {
      let variant = enum_value_name(value)
      case is_constructor_name(variant), list.key_find(seen, variant) {
        False, _ ->
          Error(UnnamableEnumValue(enum_name: enum_def.name, value:, variant:))
        True, Ok(first) ->
          Error(CollidingEnumValues(
            enum_name: enum_def.name,
            first:,
            second: value,
            variant:,
          ))
        True, Error(Nil) -> Ok([#(variant, value), ..seen])
      }
    })
    |> result.replace(Nil)
  })
}

pub fn enum_value_error_to_string(error: EnumValueError) -> String {
  case error {
    UnnamableEnumValue(enum_name:, value:, variant:) ->
      "SQD2006: value \""
      <> value
      <> "\" of enum "
      <> enum_name
      <> " cannot become a Gleam constructor (it would be \""
      <> variant
      <> "\"). Use letters, digits, '_', '-', '.', '/' or spaces, starting with a letter"
    CollidingEnumValues(enum_name:, first:, second:, variant:) ->
      "SQD2006: values \""
      <> first
      <> "\" and \""
      <> second
      <> "\" of enum "
      <> enum_name
      <> " both become the Gleam constructor "
      <> variant
  }
}

/// A Gleam constructor starts with an uppercase ASCII letter and goes
/// on with ASCII letters and digits. The prelude constructors are
/// rejected too: the generated `from_string` returns `Ok(..)`, which a
/// local `Ok` variant would shadow.
fn is_constructor_name(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] ->
      char_utils.is_uppercase_letter(first)
      && list.all(rest, fn(g) {
        char_utils.is_uppercase_letter(g)
        || char_utils.is_lowercase_letter(g)
        || char_utils.is_digit(g)
      })
      && !list.contains(["Ok", "Error", "True", "False", "Nil"], name)
    [] -> False
  }
}

pub fn enum_to_string_fn(name: String) -> String {
  string.lowercase(name) <> "_to_string"
}

pub fn enum_from_string_fn(name: String) -> String {
  string.lowercase(name) <> "_from_string"
}

/// Name of the helper that returns the enum's first variant as a
/// `zero`-style fallback. Used by generated adapter / queries
/// decoders where `decode.failure(zero, msg)` needs a concrete value
/// of the target type.
pub fn enum_default_fn(name: String) -> String {
  string.lowercase(name) <> "_default"
}

// --- Set naming utilities ---

/// Gleam type name for a single value of a MySQL `SET` column. The
/// generated value type ends in `Value` to disambiguate it from the
/// containing list — `SET('red','green')` on a column called `tags`
/// surfaces as `List(TagsValue)` so callers can pattern-match on each
/// chosen flag without colliding with the SET column name.
pub fn set_value_type_name(name: String) -> String {
  simple_pascal_case(name) <> "Value"
}

pub fn set_to_string_fn(name: String) -> String {
  string.lowercase(name) <> "_set_to_string"
}

pub fn set_from_string_fn(name: String) -> String {
  string.lowercase(name) <> "_set_from_string"
}

/// Split on the same separators as `naming.to_pascal_case` and
/// capitalise each word, lowercasing the rest so that existing names
/// such as `ACTIVE` -> `Active` stay as they were.
fn simple_pascal_case(input: String) -> String {
  input
  |> string.replace("-", "_")
  |> string.replace(" ", "_")
  |> string.replace("\t", "_")
  |> string.replace(".", "_")
  |> string.replace("/", "_")
  |> string.split("_")
  |> list.map(fn(word) {
    case string.pop_grapheme(word) {
      Ok(#(first, rest)) -> string.uppercase(first) <> string.lowercase(rest)
      Error(_) -> word
    }
  })
  |> string.join("")
}
