//// Single source of truth for the capabilities that sqlode currently
//// advertises to public consumers.
////
//// `CHANGELOG.md`, `README.md`, and any other release-facing document
//// that needs to claim "supported X" values should derive from the
//// lists below or from `manifest_markdown()` instead of restating them
//// by hand. The accompanying `test/capabilities_test.gleam` pins the
//// rendered manifest against the tracked file `doc/capabilities.md` so
//// any change to the supported set forces a conscious doc refresh.
////
//// The split between fully-supported and planned query commands
//// matches what `generate.gleam` enforces at generation time: the
//// planned commands are currently rejected with an
//// `UnsupportedAnnotation` error, so listing them as "Added" without
//// qualification (as `CHANGELOG.md` did before this module) gives a
//// false impression to public users.

import gleam/list
import gleam/string
import sqlode/model
import sqlode/runtime

pub fn supported_engines() -> List(model.Engine) {
  [model.PostgreSQL, model.MySQL, model.SQLite]
}

pub fn supported_runtimes() -> List(model.Runtime) {
  [model.Raw, model.Native]
}

pub fn supported_type_mappings() -> List(model.TypeMapping) {
  [model.StringMapping, model.RichMapping, model.StrongMapping]
}

/// Query annotations that are fully supported end-to-end: parsing,
/// analysis, and code generation all complete without the
/// `validate_unsupported_annotations` guard rejecting them.
pub fn fully_supported_query_commands() -> List(runtime.QueryCommand) {
  [
    runtime.QueryOne,
    runtime.QueryMany,
    runtime.QueryExec,
    runtime.QueryExecResult,
    runtime.QueryExecRows,
    runtime.QueryExecLastId,
  ]
}

/// Query annotations that the parser accepts for sqlc source
/// compatibility but that generation currently refuses with an
/// `UnsupportedAnnotation` error.
pub fn planned_query_commands() -> List(runtime.QueryCommand) {
  [
    runtime.QueryBatchOne,
    runtime.QueryBatchMany,
    runtime.QueryBatchExec,
    runtime.QueryCopyFrom,
  ]
}

/// Macro helpers sqlode recognises inside query files. Emitted names
/// include the `sqlode.` prefix that appears in user SQL.
pub fn supported_macros() -> List(String) {
  ["sqlode.arg", "sqlode.narg", "sqlode.slice", "sqlode.embed"]
}

/// Placeholder styles emitted for the three engines sqlode targets.
/// The pair matches the mapping in `codegen/queries.gleam`.
pub fn supported_placeholder_styles() -> List(#(model.Engine, String)) {
  [
    #(model.PostgreSQL, "DollarNumbered"),
    #(model.MySQL, "QuestionPositional"),
    #(model.SQLite, "QuestionNumbered"),
  ]
}

/// Render a Markdown manifest that the test suite pins against
/// `doc/capabilities.md`. The generated shape is intentionally stable:
/// adding a new capability changes the file, adding a new *section*
/// changes this function.
pub fn manifest_markdown() -> String {
  string.join(
    [
      "# sqlode capability manifest",
      "",
      "This file is generated from `src/sqlode/capabilities.gleam` and",
      "verified by `test/capabilities_test.gleam`. Do not edit by hand;",
      "update the capabilities module and run `just test` to refresh.",
      "",
      "## Engines",
      "",
      bullet_list(
        list.map(supported_engines(), fn(engine) {
          "- `" <> model.engine_to_string(engine) <> "`"
        }),
      ),
      "",
      "## Runtimes",
      "",
      bullet_list(
        list.map(supported_runtimes(), fn(runtime) {
          "- `" <> model.runtime_to_string(runtime) <> "`"
        }),
      ),
      "",
      "## Type mappings",
      "",
      bullet_list(
        list.map(supported_type_mappings(), fn(mapping) {
          "- `" <> model.type_mapping_to_string(mapping) <> "`"
        }),
      ),
      "",
      "## Query annotations",
      "",
      "### Fully supported",
      "",
      bullet_list(
        list.map(fully_supported_query_commands(), fn(command) {
          "- `" <> command_annotation(command) <> "`"
        }),
      ),
      "",
      "### Parsed but rejected at generation time",
      "",
      "These annotations exist in sqlc and are still parseable in",
      "`.sql` files, but sqlode currently refuses to emit code for",
      "them. See `validate_unsupported_annotations` in `generate.gleam`.",
      "",
      bullet_list(
        list.map(planned_query_commands(), fn(command) {
          "- `" <> command_annotation(command) <> "`"
        }),
      ),
      "",
      "## Macros",
      "",
      bullet_list(
        list.map(supported_macros(), fn(name) { "- `" <> name <> "(...)`" }),
      ),
      "",
      "## Placeholder styles",
      "",
      bullet_list(
        list.map(supported_placeholder_styles(), fn(entry) {
          let #(engine, style) = entry
          "- `"
          <> model.engine_to_string(engine)
          <> "` → `runtime."
          <> style
          <> "`"
        }),
      ),
      "",
    ],
    "\n",
  )
}

fn bullet_list(lines: List(String)) -> String {
  case lines {
    [] -> "(none)"
    _ -> string.join(lines, "\n")
  }
}

fn command_annotation(command: runtime.QueryCommand) -> String {
  case command {
    runtime.QueryOne -> ":one"
    runtime.QueryMany -> ":many"
    runtime.QueryExec -> ":exec"
    runtime.QueryExecResult -> ":execresult"
    runtime.QueryExecRows -> ":execrows"
    runtime.QueryExecLastId -> ":execlastid"
    runtime.QueryBatchOne -> ":batchone"
    runtime.QueryBatchMany -> ":batchmany"
    runtime.QueryBatchExec -> ":batchexec"
    runtime.QueryCopyFrom -> ":copyfrom"
  }
}
