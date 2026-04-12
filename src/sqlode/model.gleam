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

pub type ParsedQuery {
  ParsedQuery(
    name: String,
    function_name: String,
    command: QueryCommand,
    sql: String,
    source_path: String,
    param_count: Int,
  )
}
