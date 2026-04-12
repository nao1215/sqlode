import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import simplifile
import sqlode/model
import yay

pub type ConfigError {
  FileNotFound(path: String)
  FileReadError(path: String, detail: String)
  ParseError(detail: String)
  MissingField(field: String)
  InvalidValue(field: String, detail: String)
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
  use gleam_node <- result.try(require_node(node, "gen.gleam"))
  use package <- result.try(required_string(gleam_node, "package"))
  use out <- result.try(required_string(gleam_node, "out"))

  use runtime <- result.try(case optional_string(gleam_node, "runtime") {
    Some(value) ->
      model.parse_runtime(value)
      |> result.map_error(fn(detail) {
        InvalidValue(field: "sql.gen.gleam.runtime", detail:)
      })
    None -> Ok(model.Raw)
  })

  Ok(model.SqlBlock(
    name:,
    engine:,
    schema:,
    queries:,
    gleam: model.GleamOutput(package:, out:, runtime:),
  ))
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
  }
}

fn yaml_error_to_string(error: yay.YamlError) -> String {
  case error {
    yay.UnexpectedParsingError -> "Unexpected parsing error"
    yay.ParsingError(msg:, ..) -> msg
  }
}
