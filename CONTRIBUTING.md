# Contributing to sqlode

## Development setup

You need the following tools installed:

- [Gleam](https://gleam.run/) (1.x)
- Erlang/OTP (27+)
- [ShellSpec](https://shellspec.info/) for integration tests
- [just](https://github.com/casey/just) as a task runner (optional but recommended)

Clone the repository and download dependencies:

```console
git clone https://github.com/nao1215/sqlode.git
cd sqlode
gleam deps download
```

## Running tests

Run the full test suite with:

```console
just all
```

This runs format check, type check, build, unit tests, and ShellSpec integration tests in order. You can also run individual steps:

| Command | What it does |
|---------|-------------|
| `gleam format --check src/ test/` | Check formatting |
| `gleam check` | Type check |
| `gleam build --warnings-as-errors` | Build (warnings fail the build) |
| `gleam test` | Run Gleam unit tests |
| `shellspec` | Run ShellSpec integration tests |

## Project architecture

sqlode follows a pipeline: config loading, schema parsing, query parsing, query analysis, and code generation.

```
sqlode.yaml
    |
    v
config.gleam          -- load and validate YAML config
    |
    v
schema_parser.gleam   -- parse CREATE TABLE / VIEW / ENUM from SQL
    |
    v
query_parser.gleam    -- parse -- name: annotations and SQL bodies
    |
    v
query_analyzer/       -- infer parameter types and result columns
    |
    v
codegen/              -- generate params.gleam, queries.gleam, models.gleam, adapter
    |
    v
writer.gleam          -- write generated files to disk
```

Key modules:

- `src/sqlode/model.gleam` -- shared types used across the pipeline (`ScalarType`, `ParsedQuery`, `AnalyzedQuery`, `Catalog`)
- `src/sqlode/runtime.gleam` -- public API types imported by generated code (`RawQuery`, `QueryCommand`, `Value`)
- `src/sqlode/lexer.gleam` -- SQL tokenizer producing `List(Token)`
- `src/sqlode/generate.gleam` -- orchestrates the full pipeline from config to file output

## Adding a new SQL type mapping

SQL type mappings live in `model.gleam`. To add support for a new SQL type:

1. If the type maps to an existing `ScalarType` variant (e.g., `MONEY` maps to `FloatType`), add the type keyword to the appropriate pattern list in `parse_sql_type`.
2. If the type needs a new `ScalarType` variant, add the variant to the `ScalarType` type, then update `parse_sql_type`, `scalar_type_to_gleam_type`, `scalar_type_to_decoder`, and `scalar_type_to_value_function`.
3. Add a test in `test/model_test.gleam` or `test/schema_parser_test.gleam`.

## Adding a new query command

Query commands are defined in `runtime.gleam` as `QueryCommand` variants.

1. Add the variant to `QueryCommand` in `src/sqlode/runtime.gleam`.
2. Add the annotation string (e.g., `:newcmd`) to `parse_query_command` and `query_command_to_string` in `model.gleam`.
3. Handle the new command in the codegen modules (`codegen/queries.gleam`, `codegen/adapter.gleam`).
4. If the command is not yet supported, add it to `validate_unsupported_annotations` in `generate.gleam`.

## Code style

- Run `gleam format src/ test/` before committing.
- The build uses `--warnings-as-errors`, so fix all warnings.
- Prefer early errors over silent fallbacks.
- Keep private functions private; do not expose them just for testing.

## Pull request expectations

- All CI checks must pass (`just all`).
- Include tests for new behavior.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages (e.g., `feat(parser): ...`, `fix(codegen): ...`).
- One logical change per PR.

## Public documentation style

User-facing docs (README, release notes, hexdocs) follow a terse reference-oriented style. These rules apply to every PR that touches public-facing documentation; treat violations as review blockers.

- No marketing prose. Write as if documenting a standard library.
- No bold emphasis on inline phrases. Use bold only for table headers or actual UI labels.
- No emoji in code examples, tables, or prose.
- Prefer code examples over explanations. If the example is self-explanatory, delete the surrounding commentary.
- State constraints factually: "X requires Y" beats "You need to make sure that X has Y".
- Do not use second-person cheerleading ("you can easily", "just do X").
- Reference sections (type mapping table, annotation table, config options) stay normative. Migration and tutorial content goes in separate sections at the end.

### Review checklist for docs PRs

- [ ] No new bold-italic emphasis on inline phrases
- [ ] No emoji added to README, code comments, or error messages
- [ ] Each new section is either purely reference or purely tutorial — not both
- [ ] Code examples are runnable as written; any required imports are shown
- [ ] New options/flags are added to the relevant reference table, not only described in prose
