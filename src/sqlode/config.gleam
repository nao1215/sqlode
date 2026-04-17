import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlode/char_utils
import sqlode/model
import yay

pub type ConfigError {
  FileNotFound(path: String)
  FileReadError(path: String, detail: String)
  ParseError(detail: String)
  MissingField(field: String)
  InvalidValue(field: String, detail: String)
  UnsupportedFields(fields: List(String), message: String)
}

pub fn load(path: String) -> Result(model.Config, ConfigError) {
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      case error {
        simplifile.Enoent -> FileNotFound(path:)
        _ ->
          FileReadError(
            path:,
            detail: "Failed to read file: " <> simplifile.describe_error(error),
          )
      }
    }),
  )

  use docs <- result.try(
    yay.parse_string(content)
    |> result.map_error(fn(error) {
      ParseError(detail: "YAML parse error: " <> yaml_error_to_string(error))
    }),
  )

  use doc <- result.try(case docs {
    [first, ..] -> Ok(first)
    [] -> Error(ParseError(detail: "Empty YAML document"))
  })

  let root = yay.document_root(doc)

  use _ <- result.try(check_unknown_keys(root, ["version", "sql"], ""))
  use version <- result.try(parse_version(root))
  use sql <- result.try(parse_sql_blocks(root))

  Ok(model.Config(version:, sql:))
}

fn parse_version(root: yay.Node) -> Result(Int, ConfigError) {
  use node <- result.try(require_node(root, "version"))

  case node {
    yay.NodeStr("2") -> Ok(2)
    yay.NodeInt(2) -> Ok(2)
    yay.NodeStr(other) ->
      Error(InvalidValue(
        field: "version",
        detail: "expected \"2\", got " <> other,
      ))
    yay.NodeInt(other) ->
      Error(InvalidValue(
        field: "version",
        detail: "expected 2, got " <> int.to_string(other),
      ))
    _ ->
      Error(InvalidValue(
        field: "version",
        detail: "must be a string or integer",
      ))
  }
}

fn parse_sql_blocks(root: yay.Node) -> Result(List(model.SqlBlock), ConfigError) {
  use node <- result.try(require_node(root, "sql"))

  case node {
    yay.NodeSeq(items) ->
      case items {
        [] ->
          Error(InvalidValue(
            field: "sql",
            detail: "must contain at least one entry",
          ))
        _ -> list.try_map(items, parse_sql_block)
      }
    _ -> Error(InvalidValue(field: "sql", detail: "must be a list"))
  }
}

fn parse_sql_block(node: yay.Node) -> Result(model.SqlBlock, ConfigError) {
  use _ <- result.try(check_unknown_keys(
    node,
    ["name", "engine", "schema", "queries", "gen", "overrides"],
    "sql.",
  ))
  let name = optional_string(node, "name")

  use engine_text <- result.try(required_string(node, "engine"))
  use engine <- result.try(
    model.parse_engine(engine_text)
    |> result.map_error(fn(detail) {
      InvalidValue(field: "sql.engine", detail:)
    }),
  )

  use schema <- result.try(required_string_list(node, "schema"))
  use queries <- result.try(required_string_list(node, "queries"))
  use gen_node <- result.try(require_node(node, "gen"))
  use _ <- result.try(check_unknown_keys(gen_node, ["gleam"], "sql.gen."))
  use gleam_node <- result.try(require_node(gen_node, "gleam"))
  use _ <- result.try(check_unknown_keys(
    gleam_node,
    [
      "out", "runtime", "type_mapping", "emit_sql_as_comment",
      "emit_exact_table_names", "omit_unused_models", "vendor_runtime",
    ],
    "sql.gen.gleam.",
  ))
  use out <- result.try(required_string(gleam_node, "out"))

  use runtime <- result.try(case optional_string(gleam_node, "runtime") {
    Some(value) ->
      model.parse_runtime(value)
      |> result.map_error(fn(detail) {
        InvalidValue(field: "sql.gen.gleam.runtime", detail:)
      })
    None -> Ok(model.Raw)
  })

  use _ <- result.try(case engine, runtime {
    model.MySQL, model.Native ->
      Error(InvalidValue(
        field: "sql.gen.gleam.runtime",
        detail: "MySQL does not support runtime: \"native\" because no Gleam MySQL driver is available; use runtime: \"raw\" instead",
      ))
    _, _ -> Ok(Nil)
  })

  use type_mapping <- result.try(
    case optional_string(gleam_node, "type_mapping") {
      Some(value) ->
        model.parse_type_mapping(value)
        |> result.map_error(fn(detail) {
          InvalidValue(field: "sql.gen.gleam.type_mapping", detail:)
        })
      None -> Ok(model.StringMapping)
    },
  )

  let emit_sql_as_comment =
    optional_bool(gleam_node, "emit_sql_as_comment")
    |> option.unwrap(False)
  let emit_exact_table_names =
    optional_bool(gleam_node, "emit_exact_table_names")
    |> option.unwrap(False)
  let omit_unused_models =
    optional_bool(gleam_node, "omit_unused_models")
    |> option.unwrap(False)
  let vendor_runtime =
    optional_bool(gleam_node, "vendor_runtime")
    |> option.unwrap(False)

  use overrides <- result.try(parse_overrides(node))

  Ok(model.SqlBlock(
    name:,
    engine:,
    schema:,
    queries:,
    gleam: model.GleamOutput(
      out:,
      runtime:,
      type_mapping:,
      emit_sql_as_comment:,
      emit_exact_table_names:,
      omit_unused_models:,
      vendor_runtime:,
    ),
    overrides:,
  ))
}

fn parse_overrides(node: yay.Node) -> Result(model.Overrides, ConfigError) {
  case yay.select_sugar(from: node, selector: "overrides") {
    Error(_) -> Ok(model.empty_overrides())
    Ok(overrides_node) -> {
      use type_overrides <- result.try(
        case yay.select_sugar(from: overrides_node, selector: "types") {
          Ok(yay.NodeSeq(items)) ->
            list.try_map(items, fn(item) {
              let gleam_type = optional_string(item, "gleam_type")
              let db_type = optional_string(item, "db_type")
              let column = optional_string(item, "column")
              let nullable = optional_bool(item, "nullable")
              case column, db_type, gleam_type {
                Some(col), _, Some(gt) -> {
                  use _ <- result.try(validate_gleam_type(gt))
                  case string.split(col, ".") {
                    [table, col_name] ->
                      Ok(model.ColumnOverride(
                        table:,
                        column: col_name,
                        gleam_type: gt,
                      ))
                    _ ->
                      Error(InvalidValue(
                        field: "overrides.types.column",
                        detail: "must be in \"table.column\" format, got \""
                          <> col
                          <> "\"",
                      ))
                  }
                }
                _, Some(dt), Some(gt) -> {
                  use _ <- result.try(validate_gleam_type(gt))
                  Ok(model.DbTypeOverride(
                    db_type: dt,
                    gleam_type: gt,
                    nullable:,
                  ))
                }
                _, _, _ ->
                  Error(InvalidValue(
                    field: "overrides.types",
                    detail: "each entry must have \"gleam_type\" and either \"db_type\" or \"column\"",
                  ))
              }
            })
          _ -> Ok([])
        },
      )

      use column_renames <- result.try(
        case yay.select_sugar(from: overrides_node, selector: "renames") {
          Ok(yay.NodeSeq(items)) ->
            list.try_map(items, fn(item) {
              case
                optional_string(item, "table"),
                optional_string(item, "column"),
                optional_string(item, "rename_to")
              {
                Some(table), Some(column), Some(rename_to) ->
                  Ok(model.ColumnRename(table:, column:, rename_to:))
                _, _, _ ->
                  Error(InvalidValue(
                    field: "overrides.renames",
                    detail: "each rename entry must have 'table', 'column', and 'rename_to' fields",
                  ))
              }
            })
          _ -> Ok([])
        },
      )

      Ok(model.Overrides(type_overrides:, column_renames:))
    }
  }
}

fn validate_gleam_type(gleam_type: String) -> Result(Nil, ConfigError) {
  case string.is_empty(gleam_type) {
    True ->
      Error(InvalidValue(
        field: "overrides.types.gleam_type",
        detail: "must not be empty",
      ))
    False -> {
      // For module-qualified types like "myapp/types.UserId",
      // validate the type name part (after the last dot)
      let type_name = case string.split_once(gleam_type, ".") {
        Ok(#(_, name)) -> name
        Error(_) -> gleam_type
      }
      let first =
        string.first(type_name)
        |> result.unwrap("")
      case char_utils.is_uppercase_letter(first) {
        False ->
          Error(InvalidValue(
            field: "overrides.types.gleam_type",
            detail: "type name must start with an uppercase letter, got \""
              <> gleam_type
              <> "\"",
          ))
        True -> Ok(Nil)
      }
    }
  }
}

fn check_unknown_keys(
  node: yay.Node,
  known_keys: List(String),
  prefix: String,
) -> Result(Nil, ConfigError) {
  case node {
    yay.NodeMap(pairs) -> {
      let unknown =
        list.filter_map(pairs, fn(pair) {
          case pair.0 {
            yay.NodeStr(key) ->
              case list.contains(known_keys, key) {
                True -> Error(Nil)
                False -> Ok(prefix <> key)
              }
            _ -> Error(Nil)
          }
        })
      case unknown {
        [] -> Ok(Nil)
        fields ->
          Error(UnsupportedFields(
            fields:,
            message: "these sqlc options are not supported by sqlode; please remove them. Valid keys: "
              <> string.join(known_keys, ", "),
          ))
      }
    }
    _ -> Ok(Nil)
  }
}

fn required_string(
  node: yay.Node,
  selector: String,
) -> Result(String, ConfigError) {
  use value <- result.try(require_node(node, selector))

  case value {
    yay.NodeStr(text) -> Ok(text)
    _ -> Error(InvalidValue(field: selector, detail: "must be a string"))
  }
}

fn required_string_list(
  node: yay.Node,
  selector: String,
) -> Result(List(String), ConfigError) {
  use value <- result.try(require_node(node, selector))

  case value {
    yay.NodeStr(text) -> Ok([text])
    yay.NodeSeq(items) ->
      list.try_map(items, fn(item) {
        case item {
          yay.NodeStr(text) -> Ok(text)
          _ ->
            Error(InvalidValue(
              field: selector,
              detail: "must contain only strings",
            ))
        }
      })
    _ ->
      Error(InvalidValue(
        field: selector,
        detail: "must be a string or a list of strings",
      ))
  }
}

fn optional_string(node: yay.Node, selector: String) -> Option(String) {
  case yay.select_sugar(from: node, selector:) {
    Ok(yay.NodeStr(text)) -> Some(text)
    _ -> None
  }
}

fn optional_bool(node: yay.Node, selector: String) -> Option(Bool) {
  case yay.select_sugar(from: node, selector:) {
    Ok(yay.NodeStr("true")) -> Some(True)
    Ok(yay.NodeStr("false")) -> Some(False)
    Ok(yay.NodeBool(value)) -> Some(value)
    _ -> None
  }
}

fn require_node(
  node: yay.Node,
  selector: String,
) -> Result(yay.Node, ConfigError) {
  case yay.select_sugar(from: node, selector:) {
    Ok(child) -> Ok(child)
    Error(_) -> Error(MissingField(field: selector))
  }
}

pub fn error_to_string(error: ConfigError) -> String {
  case error {
    FileNotFound(path:) -> "Config file not found: " <> path
    FileReadError(path:, detail:) ->
      "Error reading config file " <> path <> ": " <> detail
    ParseError(detail:) -> "Config parse error: " <> detail
    MissingField(field:) -> "Missing required config field: " <> field
    InvalidValue(field:, detail:) ->
      "Invalid value for " <> field <> ": " <> detail
    UnsupportedFields(fields:, message:) ->
      "Unsupported config fields: "
      <> string.join(fields, ", ")
      <> " — "
      <> message
  }
}

fn yaml_error_to_string(error: yay.YamlError) -> String {
  case error {
    yay.UnexpectedParsingError -> "Unexpected parsing error"
    yay.ParsingError(msg:, ..) -> msg
  }
}
