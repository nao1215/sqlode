import gleam/string
import gleeunit/should
import simplifile
import sqlode/capabilities

/// The tracked capability manifest must equal what the module renders
/// right now. Any drift means either the code's supported set changed
/// without the doc catching up, or the doc was edited by hand. Refresh
/// `doc/capabilities.md` by copy-pasting the rendered output (see the
/// hint the test prints on failure).
pub fn manifest_matches_tracked_file_test() {
  let tracked = case simplifile.read("doc/capabilities.md") {
    Ok(content) -> content
    Error(_) -> ""
  }

  let rendered = capabilities.manifest_markdown()

  case tracked == rendered {
    True -> Nil
    False -> {
      let message =
        "doc/capabilities.md is out of sync with src/sqlode/capabilities.gleam.\n"
        <> "Regenerate the file with:\n"
        <> "  gleam run -m sqlode/scripts/print_capabilities > doc/capabilities.md\n"
        <> "or copy the expected output below verbatim:\n"
        <> "--- expected ---\n"
        <> rendered
        <> "--- end expected ---"
      should.equal(message, "")
    }
  }
}

/// Guard against accidentally dropping a supported capability — the
/// lists should be non-empty for every category sqlode actually ships.
/// If a category is genuinely empty (e.g. the macro list after a
/// sweeping rename), update the capability module alongside the change.
pub fn supported_categories_are_not_empty_test() {
  should.be_true(capabilities.supported_engines() != [])
  should.be_true(capabilities.supported_runtimes() != [])
  should.be_true(capabilities.supported_type_mappings() != [])
  should.be_true(capabilities.fully_supported_query_commands() != [])
  should.be_true(capabilities.supported_macros() != [])
  should.be_true(capabilities.supported_placeholder_styles() != [])
}

/// The Markdown manifest must at least name every category it
/// advertises. Catches structural regressions (e.g. deleting a
/// section in `manifest_markdown`) without re-asserting the exact
/// output — that part is what the snapshot test covers.
pub fn manifest_lists_every_section_test() {
  let md = capabilities.manifest_markdown()
  should.be_true(string.contains(md, "## Engines"))
  should.be_true(string.contains(md, "## Runtimes"))
  should.be_true(string.contains(md, "## Type mappings"))
  should.be_true(string.contains(md, "## Query annotations"))
  should.be_true(string.contains(md, "### Fully supported"))
  should.be_true(string.contains(
    md,
    "### Parsed but rejected at generation time",
  ))
  should.be_true(string.contains(md, "## Macros"))
  should.be_true(string.contains(md, "## Placeholder styles"))
}
