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
import gleam/result
import gleam/string
import sqlode/internal/model

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
pub fn fully_supported_query_commands() -> List(model.Annotation) {
  list.filter(model.annotations(), fn(annotation) {
    result.is_ok(model.generated_command(annotation))
  })
}

/// Query annotations that the parser accepts for sqlc source
/// compatibility but that generation currently refuses with an
/// `UnsupportedAnnotation` error.
fn planned_query_commands() -> List(model.Annotation) {
  list.filter(model.annotations(), fn(annotation) {
    result.is_error(model.generated_command(annotation))
  })
}

/// Macro helpers sqlode recognises inside query files. Emitted names
/// include the `sqlode.` prefix that appears in user SQL.
pub fn supported_macros() -> List(String) {
  ["sqlode.arg", "sqlode.narg", "sqlode.slice", "sqlode.embed"]
}

/// Placeholder styles emitted for the three engines sqlode targets.
/// Derived from `model.placeholder_style`, which the generator uses.
pub fn supported_placeholder_styles() -> List(#(model.Engine, String)) {
  list.map([model.PostgreSQL, model.MySQL, model.SQLite], fn(engine) {
    #(engine, model.placeholder_style_name(model.placeholder_style(engine)))
  })
}

/// Per-engine runtime support matrix. Each entry pairs an engine with
/// the runtimes sqlode can target for it and the Hex driver the
/// generated native adapter imports. `raw` mode is always supported
/// because the generated code never needs a driver; `native` mode
/// requires a driver and is enumerated here so docs and the manifest
/// stop relying on the flat "supported engines" list to imply parity.
type EngineSupport {
  EngineSupport(
    engine: model.Engine,
    raw: Bool,
    native: Bool,
    /// Hex package name imported by the generated native adapter, or
    /// `"—"` when no native runtime is supported. Avoids dragging
    /// `gleam/option` into the public API for a single field.
    native_driver: String,
  )
}

fn engine_runtime_support() -> List(EngineSupport) {
  [
    EngineSupport(
      engine: model.PostgreSQL,
      raw: True,
      native: True,
      native_driver: "pog",
    ),
    EngineSupport(
      engine: model.MySQL,
      raw: True,
      native: True,
      native_driver: "shork",
    ),
    EngineSupport(
      engine: model.SQLite,
      raw: True,
      native: True,
      native_driver: "sqlight",
    ),
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
      "This file is generated from `src/sqlode/internal/capabilities.gleam` and",
      "verified by `test/capabilities_test.gleam`. Do not edit by hand;",
      "update the capabilities module and run `just regen-capabilities`.",
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
      "## Engine / runtime support",
      "",
      "| Engine | Raw | Native | Native driver |",
      "| --- | --- | --- | --- |",
      string.join(
        list.map(engine_runtime_support(), fn(e) {
          "| `"
          <> model.engine_to_string(e.engine)
          <> "` | "
          <> yes_no(e.raw)
          <> " | "
          <> yes_no(e.native)
          <> " | "
          <> case e.native {
            True -> "`" <> e.native_driver <> "`"
            False -> "—"
          }
          <> " |"
        }),
        "\n",
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
          "- `" <> model.annotation_text(command) <> "`"
        }),
      ),
      "",
      "### Parsed but rejected at generation time",
      "",
      "sqlc has these annotations. sqlode reads them and stops generation",
      "with an error.",
      "",
      bullet_list(
        list.map(planned_query_commands(), fn(command) {
          "- `" <> model.annotation_text(command) <> "`"
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

fn yes_no(supported: Bool) -> String {
  case supported {
    True -> "yes"
    False -> "no"
  }
}
