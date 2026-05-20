# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.31.0] - 2026-05-21

### Added

- `sqlode/runtime.raw_query_simple/6`: thin wrapper around `raw_query/7` that supplies `slice_info: fn(_) { [] }` so hand-rolled queries without slice-expanded `IN ($N)` placeholders no longer need to repeat the always-empty lambda at every call site. `sqlode generate` codegen continues to emit `raw_query/7` (or the bare constructor) so slice-bearing queries are unaffected. (#584)
- `sqlode/runtime.ExpandError` now has four refined variants — `EmptySlice(at_placeholder: Int)`, `SliceStartNonPositive(start: Int)`, `SliceStartAfterParams(start: Int, total: Int)`, and `SliceLengthExceedsParams(start: Int, length: Int, total: Int)` — that `expand_slice_placeholders_checked` returns in place of the legacy `SliceIndexOutOfRange(0, 0)` umbrella, so callers can distinguish "the supplied slice was empty" from "the 1-based start index was non-positive" from "the slice spilled past `total_params`" without parsing the integer fields. The legacy `SliceIndexOutOfRange` variant stays in the type for pre-#585 source compatibility (the strict validator no longer produces it; the panicking `expand_slice_placeholders` keeps emitting it via its lenient validator path). The `ExpandError` doc-comment now also spells out the 1-based indexing convention used by all `start` / `at_placeholder` fields. (#585)

## [0.30.0] - 2026-05-18

### Fixed

- `sqlode_ffi`: replaced the deprecated `catch port_close(Port)` form with `try port_close(Port) catch _:_ -> ok end`. The old expression form of `catch` is deprecated in recent OTP releases and emitted a `'catch ...' is deprecated; please use 'try ... catch ... end' instead` warning at every `gleam build` of any project that depends on `sqlode`. The new form preserves the original intent (swallow any error when closing an already-closed port). (#579)
- `sqlode/internal/version`: bumped the `version` constant from `0.15.0` to `0.29.0` so `sqlode version` reports the package version actually shipped (it had drifted ~14 releases out of date). Added a `version_constant_matches_gleam_toml_test` that reads `gleam.toml` at test time and cross-checks the constant, so a future release bump cannot ship a stale CLI version. (#581)

### Documentation

- README "Quickstart (SQLite)" section now shows the full `sqlode.yaml` structure with `runtime: "native"` correctly nested under `sql[].gen.gleam.runtime`. A top-level `runtime:` (where the original prose was ambiguous) is rejected with `Unsupported config fields: sql.runtime`, so callers hand-writing the yaml from the README needed to see the actual nesting. (#580)

## [0.29.0] - 2026-05-16

### Documentation

- README quick-start now passes `--runtime=native` to `sqlode init` and explains the choice next to the `--engine` flag. The flag was already wired in the CLI but the README still showed the bare `--engine=sqlite` form, so first-time users had to either accept the default `runtime: "raw"` or edit `sqlode.yaml` post-init to opt into the typed adapter output. Surfacing the flag at the moment of engine selection removes the post-edit step. The CLI usage block further down also lists `[--engine=...] [--runtime=...]` so the discoverability story is consistent. (#568)

### Changed

- **BREAKING**: `sqlode/runtime.QueryCommand` variants drop the `Query` prefix: `QueryOne` → `One`, `QueryMany` → `Many`, `QueryExec` → `Exec`, `QueryExecResult` → `ExecResult`, `QueryExecRows` → `ExecRows`, `QueryExecLastId` → `ExecLastId`, `QueryBatchOne` → `BatchOne`, `QueryBatchMany` → `BatchMany`, `QueryBatchExec` → `BatchExec`, `QueryCopyFrom` → `CopyFrom`. The prefix repeated information already encoded in the type name and module path (`sqlode/runtime.QueryCommand`); every pattern match against the type carried it on every arm. Fully-qualified call sites read `runtime.Many` / `runtime.BatchExec` now. Companion to the `runtime.Value` rename in #570 — both pre-1.0 sweeps land together so callers face one regenerate-and-update cycle. (#571)
- **BREAKING**: `sqlode/runtime.Value` variants drop the `Sql` prefix: `SqlNull` → `Null`, `SqlString` → `String`, `SqlInt` → `Int`, `SqlFloat` → `Float`, `SqlBool` → `Bool`, `SqlBytes` → `Bytes`, `SqlArray` → `Array`. The prefix repeated information already encoded in the package and module name (`sqlode/runtime`); every pattern match against the type carried it on every arm. Fully-qualified call sites read `runtime.Int` / `runtime.String` now, which lines up with the wording of the underlying driver primitives (`sqlight.text`, `sqlight.int`, ...). Callers who hold codegen-emitted adapter code that pattern-matches `runtime.Sql*` will need to regenerate it after upgrading — the bundled `pog` / `sqlight` / `shork` value adapter templates have already been migrated to the new names so the next `sqlode generate` produces matching output. (#570)

### Added

- `sqlode/runtime.raw_query/7`: the same hand-rolled `RawQuery` constructor previously named `raw_query_for_test/7`, without the suffix that made library-mode callers think the helper was test-only. Behaviour is identical; the rename is purely a discoverability fix for callers using `sqlode/runtime` as a library (no escript, no `sqlode generate` codegen). Production callers who run codegen continue to use the `RawQuery` values `sqlode generate` produces from declarative SQL fixtures. (#569)

### Deprecated

- `sqlode/runtime.raw_query_for_test/7`: now a `@deprecated` thin alias of `raw_query/7`. The `_for_test` suffix discouraged the only sanctioned non-constructor path from library-mode use, which was the friction reported in the issue. Callers see the deprecation warning at their own call site and migrate at their own pace. (#569)

### Documentation

- `sqlode/runtime.PlaceholderStyle`: docstring expanded with an engine-mapping table that pairs each variant with the databases that accept its syntax (PostgreSQL / MySQL / SQLite). The previous docstring framed `QuestionPositional` as MySQL-only, so SQLite users landing on the variant list saw no clearly-labelled sqlite option even though bare `?` is the canonical SQLite placeholder. Per-variant doc-comments also call out which engines accept (or reject) each syntax. (#572)

## [0.28.0] - 2026-05-11

### Fixed

- `runtime.expand_slice_placeholders_checked` no longer panics for
  `total_params < 0`. Pre-fix the `_checked` variant validated `slices`
  but forwarded a negative `total_params` to
  `expand_slice_placeholders`, where the `int.range` loop reached
  `param_marker(0)` and crashed the process (the post-#551 hardening
  rejects index 0 on the marker constructor). The validator now
  rejects negative `total_params` upstream with a new
  `TotalParamsNegative` variant on `ExpandError`, restoring the
  `_checked` naming contract that no user input ever panics. The
  non-checked `expand_slice_placeholders` still panics on the same
  input but with a clearer message that names the offending value
  and points callers at the `_checked` variant. (#565)

## [0.27.0] - 2026-05-10

### Added

- Property-based tests using
  [metamon](https://github.com/nao1215/metamon) covering the
  `sqlode/runtime` value encoders / marker helpers and the
  `sqlode/internal/naming` case converters. Lives in
  `test/sqlode_metamon_test.gleam`. Highlights: `runtime.null` /
  `string` / `int` / `bool` / `bytes` / `array` round-trip
  through their `Sql*` constructors and preserve length;
  `runtime.param_marker_checked` / `slice_marker_checked` accept
  positive 1-based indices and surface
  `MarkerIndexNonPositive(index:)` for zero / negative inputs;
  the two markers have distinct prefixes so a swap at the call
  site cannot produce a colliding identifier.
  `naming.to_pascal_case` / `to_snake_case` are idempotent and
  drop `_` / `-` / `.` separators; `to_snake_case` produces
  lowercase output for alpha input;
  `naming.normalize_identifier` is idempotent and lowercases
  alpha input; `naming.singularize` is idempotent.

## [0.26.0] - 2026-05-09

### Fixed
- **Schema/query mismatch now surfaces as `TableNotFound` instead of
  the misleading `ParameterTypeNotInferred` "use CAST(?) AS INTEGER"
  hint.** When a query references a table not in `schema.sql`,
  `oaspec generate` previously failed type inference for the
  WHERE-clause placeholder ("could not infer type for parameter ?N")
  with a CAST suggestion that does not actually fix the underlying
  problem. The analyzer now checks every table the query references
  against the catalog before parameter inference runs and reports the
  first missing table name. Covers SELECT (FROM/JOIN), INSERT INTO,
  UPDATE, and DELETE; UnstructuredStatement (parser-internal fallback
  for shapes the IR does not yet model) keeps the original behavior
  to avoid false positives. (#557)
- **`sqlode init` stub schema now adds `DEFAULT CURRENT_TIMESTAMP` to
  `created_at`** (across SQLite / MySQL / PostgreSQL templates) so the
  documented `init → generate → gleam run` happy path actually inserts
  one row. Previously the stub schema declared
  `created_at TEXT NOT NULL` (or DATETIME / TIMESTAMP) without a default
  while the stub `CreateAuthor` query only set `name` and `bio` — the
  first call to the generated `create_author` failed with a
  `ConstraintNotnull` violation. Adding `DEFAULT CURRENT_TIMESTAMP`
  matches the column's intent (filled by the database, not the
  application) and is uniform across the three engines. (#558)
- **`sqlode init` log indent**: the first "Created …" line now uses the
  same two-space indent as the schema/query lines below it, so the three
  paths align in the user's terminal. (#558)

## [0.25.0] - 2026-05-08

### Changed
- **codegen**: generated `prepare_*` helpers now emit same-name
  labelled arguments (`prepare_create_session(project project: String,
  note note: String, ...)` etc.) so call sites can use the labelled
  form (`prepare_create_session(project: "p", note: "n", ...)`) and
  catch swapped multi-`String` arguments at compile time. Existing
  positional callers continue to compile unchanged because Gleam
  accepts both forms when every parameter has a label. The label name
  is the column name from the source `.sql`. (#554)

## [0.24.0] - 2026-05-08

### Fixed
- **runtime**: `runtime.param_marker/1` and `runtime.slice_marker/1`
  now panic when `index < 1` with
  `"sqlode.runtime.<param_marker|slice_marker>: index must be >= 1
  (1-based) (got <n>)"`. The runtime expand step is keyed by 1-based
  positions; previously a `0` or negative index would either fail to
  round-trip through `expand_slice_placeholders` (leaving the literal
  marker in the SQL → runtime SQL syntax error) or silently match an
  unrelated marker (silent SQL-shape bug). The codegen path always
  emits 1-based indices so production users are unaffected; the new
  guard catches buggy hand-rolled `RawQuery` values and custom adapter
  authors. Symmetric front-end concern to #546
  (`expand_slice_placeholders` validation). (#551)

### Added
- **runtime**: `runtime.param_marker_checked/1` and
  `runtime.slice_marker_checked/1` return
  `Result(String, MarkerError)` instead of panicking. Use the checked
  variants when `index` comes from a custom adapter or hand-rolled
  `RawQuery` and the caller wants to surface bookkeeping mistakes
  without crashing the process. Same shape as the existing
  `expand_slice_placeholders_checked/4`. The new
  `runtime.MarkerError` type carries the offending index in its
  `MarkerIndexNonPositive(index)` variant. (#551)

## [0.23.0] - 2026-05-07

### Added

- **runtime**: `runtime.raw_query_for_test/7` — labelled-argument
  helper for constructing a `RawQuery(p)` directly without going
  through the codegen pipeline. Intended for custom-adapter authors
  (in-memory test database, SQLite WASM, query-log middleware, ...)
  and for property / regression tests against `prepare` /
  `expand_slice_placeholders`. The README's new "Writing custom
  adapters" section walks through the full pattern, and
  `test/runtime_property_test.gleam` carries three worked examples
  (single-param `SELECT`, three-style slice expansion, and the empty-
  slice `IN (NULL)` rewrite). (#547)
- **runtime**: `expand_slice_placeholders_checked` and the
  `ExpandError` type (`SliceLengthNegative` / `SliceIndexOutOfRange`)
  expose validation failures as a `Result` instead of panicking. Use
  this from custom adapters or hand-rolled `RawQuery` consumers that
  want to surface bookkeeping mistakes without crashing the process;
  the codegen-driven path keeps using the panicking
  `expand_slice_placeholders`. (#546)

### Changed

- **Breaking (runtime)**: `expand_slice_placeholders` now panics at
  the start of the call when `slices` is malformed: a negative slice
  length, or a slice index outside `[1, total_params]`. The previous
  behaviour silently produced broken output — a negative length was
  rounded to its absolute value and emitted that many placeholders,
  while an out-of-range index left the corresponding
  `__sqlode_slice_<idx>__` marker in the SQL for the engine to
  reject. Failing visibly catches codegen / adapter bookkeeping
  mistakes near their cause. The panic message names the offending
  index and the bound that was violated. (#546)

## [0.22.0] - 2026-05-05

### Added

- **codegen**: `sqlode generate` now runs `gleam format` on the
  generated files as the last step of the pipeline. Previously every
  record constructor and `decode.field(...)` chain landed on a single
  line that could exceed 200 characters, masking diffs and pointing
  `git blame` at one line per record. The CLI prints
  `Formatted generated code` on success and a non-fatal warning to
  stderr if `gleam` is missing or the formatter exits non-zero — the
  written files remain valid either way. (#543)

## [0.21.0] - 2026-05-04

### Documentation

- **readme**: Lead with a SQLite quickstart that walks an empty project
  to a typed adapter using only `gleam add sqlode sqlight` and the
  `init` / `generate` commands. The existing tutorial under
  `doc/tutorials/getting-started-sqlite.md` and the
  `examples/sqlite-basic/` runnable project are linked as the default
  onboarding route. The full install matrix (one-line installer,
  manual escript, Docker, mise) and feature reference stay in place
  but no longer dominate the first screen. (#539)

### Internal

- **integration**: Refresh `integration_test/warmup/manifest.toml` so
  its sqlode pin matches the published version. The lockfile had
  drifted to v0.19.0 and was breaking `just integration-prepare` (and
  therefore `just all`) on a clean checkout.

## [0.20.0] - 2026-04-30

### Removed

- **docs/verify**: drop the "verification roadmap" promise of a
  future DB-backed analysis phase. The static `sqlode verify` (schema
  parsing + query analysis + `query_parameter_limit`) covers what
  users actually need; running `EXPLAIN` / prepared-query validation
  against a real database adds operational complexity (driver
  dependency, container management, multi-engine support) without a
  concrete pain point driving it. The README's "Verification
  roadmap" subsection and the "DB-backed analyser is on the roadmap"
  cell in the sqlc comparison table are removed; the doc-comment in
  `src/sqlode/internal/verify.gleam` no longer references the
  abandoned multi-phase plan. (#528)

### Added

- **overrides**: explicit `encode` / `decode` codec hooks for custom
  type overrides (issue #529). Opaque domain types
  (`pub opaque type UserId { UserId(Int) }`) are now usable from
  generated code without relaxing their wrapper invariant — declaring
  `encode: user_id_to_int` and `decode: int_to_user_id` on the
  override pipes parameter values through the user's encode function
  before the runtime primitive encoder, and composes the user's
  decode function on top of the underlying primitive decoder via
  `decode.map(...)`. Hooks are resolved relative to the module of
  `gleam_type` (so `gleam_type: "myapp/types.UserId"` plus
  `encode: "user_id_to_int"` emits `types.user_id_to_int(value)` at
  the call site), and the pair is required as a unit — providing
  only one half is rejected at config-load time. The transparent-
  alias warning is suppressed when codec hooks are supplied; the
  README's "Custom type aliases" subsection now documents both
  paths. The new `model.CodecHooks` type and the `codec` field on
  `TypeOverride` and `ScalarType.CustomType` are internal-only
  (`internal_modules`); `*.gleam` consumers see no API change. (#529)
- **ci/runtime**: JavaScript-target test lane. The cross-target laws
  in `sqlode/runtime` (Value encoders, `prepare`, marker-based
  placeholder / slice expansion across PostgreSQL `$N`, SQLite `?N`,
  and MySQL `?` styles, plus the literal/comment-preservation edge
  cases) are now exercised on Node by a dedicated entry point
  (`test/sqlode_js_test.gleam`). Both `ci.yml` (the `Build
  (JavaScript)` job) and `release.yml` (the `Build and verify` job)
  invoke `gleam run -m sqlode_js_test --target javascript`, and
  `just all` does the same locally via the new `just test-javascript`
  recipe. The dedicated entry exists because gleeunit's JavaScript
  auto-discovery would otherwise transitively load `glint`, whose
  current generated JavaScript fails to parse on Node — the file
  documents the rationale and the call list mirrors every
  `runtime_test` function so the JavaScript lane stays in parity
  with the Erlang lane for the runtime surface generated code calls
  into. (#527)

### Fixed

- **integration tests**: drop the `GetAuthorsByIds` and
  `GetAuthorsByIdsAndNames` queries from the SQLite extended fixture
  (`test/fixtures/sqlite_extended_query.sql`) and the matching tests
  from `integration_test/fixtures/sqlite_extended_test.gleam`. Both
  queries used `sqlode.slice()` against the SQLite engine, which v0.19.0
  (#531 / #533) made an explicit `UnsupportedSliceForEngine` validation
  error. The integration lane was the last consumer of that
  combination, so the v0.19.0 release CI failed at
  `bash integration_test/run.sh` and never reached `gleam publish` or
  the GitHub release step. PostgreSQL slice coverage is unchanged and
  is regression-tested by `verify_test.gleam`.

## [0.19.0] - 2026-04-30

### Changed

- **verify / generate**: `sqlode.slice(...)` is now rejected at
  static-analysis time when the block targets `sqlite` or `mysql`,
  with a structured `UnsupportedSliceForEngine(query_name, engine)`
  diagnostic. Previously the same configuration shipped runtime code
  that panicked the moment a `runtime.SqlArray` reached
  `value_to_sqlight` / `value_to_shork`. Closing the loop on the
  static side means unsupported array/native-adapter combinations
  fail at `sqlode generate` / `sqlode verify` instead of at request
  time. PostgreSQL behaviour is unchanged. README documents the
  raw-runtime / inline-placeholder fallbacks for queries that
  genuinely need IN-clause expansion against SQLite / MySQL. (#531)

## [0.18.0] - 2026-04-29

### Changed

- **glinter `unused_exports` flipped from `"off"` back to `"error"`**,
  closing the follow-up tracked in v0.17.0's release notes for #520.
  After the `internal/*` move, 15 `pub` items in internal modules
  had no in-tree caller. Most were demoted to module-private (`fn` /
  `type`); a few were dead code from earlier IR shapes
  (`StructuredQuery` / `RichQuery` types in `query_ir`,
  `infer_insert_params` and its helpers in `query_analyzer`,
  `parse_placeholder_index` and `find_set_patterns` in
  `token_utils`) and were deleted outright. `sqlode/runtime` keeps
  its `pub` items intentional — they are consumed by
  sqlode-generated code in downstream packages, which `glinter`
  cannot see, so the file is added to `[tools.glinter.ignore]` for
  this rule. The `internal_modules` boundary already protected the
  hex API surface; this PR makes the in-tree contract match. (#520)

## [0.17.0] - 2026-04-28

### Changed

- **Internal modules moved under `sqlode/internal/*` (BREAKING for any
  caller importing internal modules)**. The lexer, query parser,
  query IR, schema parser, codegen pipeline, query analyzer, model,
  naming, capabilities, config, generate, verify, validate, writer,
  type_mapping, sql_paths, char_utils, version, and the
  `query_analyzer/*` and `codegen/*` subtrees all moved from
  `src/sqlode/<X>` to `src/sqlode/internal/<X>`. `gleam.toml` adds
  `internal_modules = ["sqlode/internal/**", "sqlode/scripts/**"]`
  so those modules are excluded from `gleam docs` output and from
  the documented hex API surface. `sqlode` (CLI entry),
  `sqlode/cli`, and `sqlode/runtime` stay at the top of the tree
  and are the only modules SemVer-tracked going forward. No
  consumer that uses only the CLI or `import sqlode/runtime` from
  generated code is affected — the move only changes the import
  path for in-tree tests and any external caller that was reaching
  into internal IR. (#520)

### Notes

- `unused_exports` stayed `"off"` for this PR. Flipping it to
  `"error"` after the move surfaced ~15 internal `pub` items that
  have no in-tree caller; demoting them cascades into a chain of
  newly-unused private callees that needs its own pruning pass.
  Tracked as a follow-up to #520. The `internal_modules` entry
  already removes those items from the documented hex API contract,
  which is the headline win the issue asked for.

## [0.16.0] - 2026-04-28

### Added

- JavaScript target compilation for `sqlode/runtime` and generated
  modules. `gleam.toml` no longer pins `target = "erlang"`; the four
  Erlang FFI declarations in `sqlode.gleam` and `sqlode/cli.gleam`
  (`init:stop/1`, `sqlode_ffi:is_stdout_terminal/0`,
  `sqlode_ffi:no_color_env/0`) are gated with `@target(erlang)` and
  paired with no-op JavaScript bodies, so the CLI surface still
  compiles on JavaScript without referencing absent BEAM primitives.
  The CLI itself is intentionally BEAM-only at runtime — `escript`
  is BEAM territory and the supported drivers (`pog`, `shork`,
  `sqlight`) all run on the BEAM. Generated modules and
  `sqlode/runtime` are now importable from a JavaScript-target Gleam
  app, which lets a consumer pair the same compile-time-safe SQL →
  row decoder shape with a fetch-based driver (Cloudflare D1,
  serverless Postgres, etc.). CI now runs a `Build (JavaScript)`
  job that verifies the package compiles cleanly under
  `gleam build --target javascript`. (#519)

## [0.15.0] - 2026-04-28

### Changed

- **param inference (BREAKING)**: A placeholder bound by an equality
  / comparison / `LIKE` predicate (`WHERE col <op> ?`,
  `UPDATE … SET col = ?`, `WHERE col [I]LIKE ?`) or an `IN` predicate
  (`WHERE col IN (?)`) on a nullable schema column no longer inherits
  the column's `nullable: True` flag. The generated parameter type
  drops the `Option(_)` wrapper because:
  - `WHERE col = ?` against `None` would emit `WHERE col = NULL`,
    which never matches by SQL `=` semantics — surfacing `Some(_)` /
    `None` choice at the call site invites bugs that always return
    an empty result set.
  - `UPDATE … SET col = ?` is the user supplying the new value;
    clearing to NULL is expressed in SQL as a literal
    `SET col = NULL`, not as a parameter. There is no callable
    `None` case here.

  INSERT VALUES sites (where `None` legitimately writes NULL on the
  wire) keep the column's nullability — they go through a different
  inference pass and are unaffected. Callers that previously wrote
  `Some(value)` at every comparison-style call site now drop the
  wrapper and pass the bare value; callers that passed `None` (an
  unreachable code path under the old contract too) need to rewrite
  to a separate `IS NULL` query, mirroring how SQL itself expresses
  the same condition. (#512)

### Fixed

- **lexer / generated SQL**: `INSERT OR IGNORE` / `INSERT OR ABORT`
  / `INSERT OR FAIL` no longer render as the mixed-case
  `insert or IGNORE / ABORT / FAIL ...` string. The conflict-resolution
  keywords `IGNORE`, `ABORT`, and `FAIL` were not in the recognized SQL
  keyword list, so they survived as preserved-case `Ident` tokens
  while their `INSERT` / `OR` / `INTO` siblings normalised to
  lowercase via the `Keyword` token path. Promoting the three to
  keywords restores consistent lowercasing across the rendered SQL
  string in `RawQuery.sql` / `runtime.QueryInfo.sql` and matches the
  treatment already given to `replace` / `rollback`. Pattern matchers
  in `query_analyzer/token_utils.is_insert_or_action_token` now
  accept both the new `Keyword` form and the legacy `Ident` form so
  callers that hand-build token streams continue to work. Note: this
  fix normalises the three specific words the issue identified;
  full source-case preservation across all keywords would require an
  architectural change to how the lexer stores `Keyword` tokens
  (currently the lowercased canonical form) and is left as a
  follow-up. (#513)

### Changed

- **naming**: `singularize` (and therefore `table_type_name`) now
  treats `media`, `data`, `criteria`, `agenda`, `schemata`, `bacteria`,
  and `phenomena` as already-singular mass nouns rather than rewriting
  them to their formal Latin singular (`Medium`, `Datum`, `Criterion`,
  `Agendum`, `Schema`, `Bacterium`, `Phenomenon`). A `media` table
  generates a Gleam type called `Media`, not `Medium` — matching what
  most modern English speakers expect. Projects that genuinely want the
  Latin form can still keep the source name singular (e.g. `medium`)
  in the schema. (#514)

## [0.14.0] - 2026-04-27

### Fixed

- `CAST(sqlode.arg(name) AS TYPE)` now resolves type inference in
  `UPDATE ... SET` clauses. Previously, both column-based inference and
  SQL-standard `CAST()` extraction failed for parameters wrapped in CAST
  inside SET assignments. The IR-level `assignment_match` now unwraps
  `Cast(Param)` via `param_of`, and a new `scan_cast_hints` token walker
  extracts `CAST(? AS type)` patterns with proper occurrence-based
  indexing for all engines. (#501)
- The SQLite native adapter no longer silently converts `SqlArray`
  values to `NULL`. The generated `value_to_sqlight` function now panics
  with a descriptive message when it encounters `SqlArray`, which should
  never reach the native adapter in correct usage. The MySQL adapter
  receives the same treatment. (#502)
- SQL comments containing `-- name:` without a valid colon-prefixed
  command (e.g. `-- name: this explains the column`) are now treated as
  regular comments instead of being misinterpreted as query annotations.
  Intentional annotations with invalid commands (e.g. `-- name: Foo
  :invalid`) still produce errors. (#503)
- `sqlode verify` now replicates all validation steps from `sqlode
  generate`: empty query list detection, `apply_column_renames`, and
  `disambiguate_param_names`. Previously a config could pass `verify`
  but fail `generate`. (#504)
- Generated enum and set decoders now include the actual received value
  in the `decode.failure` error message (e.g. `"known status variant,
  got 'suspended'"`), making schema-drift mismatches diagnosable.
  Previously the error said only `"valid status value"` with no
  indication of what was received. (#505)

## [0.13.0] - 2026-04-27

### Added

- mise/asdf-compatible plugin for version-managed installs. Users can now
  run `mise plugin add sqlode` and `mise install sqlode@latest` to manage
  sqlode alongside their Gleam/Erlang toolchain. (#433)

## [0.12.0] - 2026-04-27

### Fixed

- `QueryInfo.sql` now shows engine-native placeholders (`$1` for PostgreSQL,
  `?1` for SQLite, `?` for MySQL) instead of internal `__sqlode_param_N__`
  markers. This makes the metadata suitable for logging, debugging, and
  query cache keys without additional processing. (#496)

## [0.11.0] - 2026-04-27

### Fixed

- `LIMIT sqlode.arg(name)` and `OFFSET sqlode.arg(name)` now resolve
  on every engine without requiring an explicit cast. Previously the
  SQLite path failed type inference with
  `could not infer type for parameter ?N. Use CAST(? AS INTEGER) to
  specify the type`, and the suggested workaround
  `CAST(sqlode.arg(name) AS INTEGER)` did not help because the macro
  expanded to `?` before the surrounding cast was inspected. The
  analyzer now derives `IntType` from the SQL-level integer context
  (LIMIT/OFFSET expressions must evaluate to an integer), pinning
  every placeholder reachable from those clauses regardless of
  engine. Implemented in `param_inferencer.extract_int_context_params`
  (token-level walk that tracks placeholder occurrence indices to
  match `placeholder.build`'s assignment, since SQLite anonymous `?`
  placeholders carry `Param.index = 0` in the IR by design). User-
  written `CAST(? AS <type>)` still wins when present, since
  `extract_type_casts` is layered on top. Pagination queries
  (`SELECT … LIMIT ? OFFSET ?`) work as written. (#491)
- `:one` queries that have no FROM clause and project a single scalar
  expression (e.g. `SELECT last_insert_rowid() AS id;`,
  `SELECT random() AS r;`) now produce a complete row type and a
  matching decoder. Previously the column inferencer treated the
  table-less SELECT as having no columns and returned `Ok([])`, so
  `models.gleam` lacked the row type while the generated adapter
  still referenced it — the consuming project failed to compile.
  Two new pieces wire this up: (1) `infer_columns_from_tokens_scoped`
  now calls a new `infer_table_less_columns` helper when no FROM
  table is in scope, which uses the existing
  `infer_expression_type_from_tokens` path to recover the column
  type/nullability; (2) the SQLite-side function dictionary
  (`type_inference.infer_function_body` and
  `column_inferencer.classify_function`) gains
  `last_insert_rowid` so the int return type and non-null property
  are recognised. Bare column references without a FROM clause are
  still rejected with `UnsupportedExpression`. (#492)

## [0.10.0] - 2026-04-26

### Fixed

- `INSERT INTO ... VALUES (..., CAST(? AS BLOB), ...)` and
  similar `CAST(? AS <type>)` slots now consume a parameter
  position correctly. Previously `infer_insert_params` only
  matched a bare `[Placeholder]` token and silently skipped
  CAST-wrapped placeholders, which shifted every subsequent
  column-to-parameter mapping by one and surfaced as
  "could not infer type" on a column the user never touched.
  As a side-effect the BLOB-column scenarios reported in the
  Issue (writes into BLOB columns, `WHERE blob_col = ?`,
  `CAST(? AS BLOB)` overrides) now generate cleanly with the
  correct `BitArray` parameter type. (#477)
- SQLite's `INSERT OR <conflict-action> INTO ...` syntax
  (`INSERT OR IGNORE`, `INSERT OR REPLACE`, `INSERT OR ABORT`,
  `INSERT OR FAIL`, `INSERT OR ROLLBACK`) now analyses identically
  to a plain `INSERT`. Previously the analyser only matched the
  bare `INSERT INTO` shape and surfaced "could not infer type for
  parameter" for every parameter when the conflict-action
  qualifier was present, forcing callers to drop to raw sqlight
  for upsert / idempotent-insert queries. Three call sites
  (`token_utils.find_insert_loop`,
  `column_inferencer.detect_dml_target`,
  `expr_parser.parse_insert_body`) now route through a shared
  `token_utils.strip_insert_or_action` helper. (#478)
- A column literally named `type` no longer trips the analyser
  with `unsupported expression "type"`. `type` is not a reserved
  keyword in any of the three engines sqlode supports (SQLite /
  PostgreSQL / MySQL all accept it as a non-reserved identifier),
  so a query like `SELECT id, type FROM blobs` now analyses and
  generates cleanly. The lexer no longer reserves `type` as a
  Keyword token; the schema-parser paths that legitimately need
  to recognise it (`CREATE TYPE`, `DROP TYPE`,
  `ALTER COLUMN ... TYPE`, `ALTER COLUMN ... SET DATA TYPE`) now
  do a case-insensitive `Ident` match instead. Existing
  `CREATE TYPE name AS ENUM (...)` schemas keep working
  unchanged. (#479)
- `naming.to_snake_case` now preserves trailing digit suffixes
  attached to the preceding letter run, so column names like
  `sha256` / `utf8` / `base64` / `oauth2` / `ipv4` / `md5` / `s3` /
  `http2` are emitted as `sha256` etc. in generated Gleam,
  rather than the previous `sha_256` / `utf_8` / `base_64` …
  shapes that read like a division. The digit→letter direction
  stays a split point (e.g. `256sha` → `256_sha`) — the
  convention is asymmetric. PascalCase / camelCase inputs follow
  the same rule (`Sha256Hash` → `sha256_hash`, `GetV2Author` →
  `get_v2_author`). (#480)

## [0.9.0] - 2026-04-26

### Changed

- `sqlode --help` no longer renders the same usage information
  twice. Previously a manually-authored `global_help` block printed
  first, followed by glint's auto-generated `USAGE: / SUBCOMMANDS:`
  layout — same content, two formats. The manual block is
  removed; glint's auto-generated layout is now the single source
  of truth, so the two views cannot drift. Per-subcommand help
  (`sqlode generate --help`, `sqlode init --help`, etc.) continues
  to use each command's `glint.command_help(...)` block, which
  already carried the auto-discovery and example details that the
  removed global block duplicated. (#467)
- The CLI now rewrites the previous misleading
  `command not found` diagnostic into a class-specific message that
  names the actual failure mode:
  - no arguments →
    `error: missing subcommand. Run 'sqlode --help' to see available
    commands.`
  - leading-dash argument (e.g. `--xyz`, `-h`, `--version`) →
    `error: unrecognized option '<arg>'. Run 'sqlode --help' to see
    available options.`
  - non-flag, non-subcommand argument (e.g. `foo`) →
    `error: unknown subcommand '<arg>'. Run 'sqlode --help' to see
    available commands.`

  The rewriting is in `sqlode.rewrite_error` and is pinned by tests;
  errors that did NOT originate from glint's `command not found`
  path (config-load failures, generate-time errors, etc.) reach the
  user verbatim. (#466)
- The CLI now sends error diagnostics (unknown flag / no-args /
  invalid subcommand) to **stderr** with exit code 1, matching the
  POSIX/CLIG convention. Pipelines like
  `sqlode | jq` no longer receive help-as-error noise on jq's
  stdin, and `sqlode <bad> 1>out 2>err` cleanly separates
  requested output from diagnostics. Explicit `--help`
  invocations still print to stdout (the help text is the
  requested output in that case). The dispatch is implemented in
  `sqlode.main`, which now drives `glint.execute` itself instead
  of going through `glint.run`. (#465)
- The CLI now emits ANSI escape codes in `--help` output only when
  stdout is connected to an interactive terminal AND the
  `NO_COLOR` environment variable is unset (or set to the empty
  string). `sqlode --help > file.txt`, `sqlode --help | less`, and
  `NO_COLOR=1 sqlode --help` no longer leak colour control
  sequences into non-ANSI consumers, matching the convention from
  <https://no-color.org/> and CLIG. The decision logic is in
  `cli.decide_color_emission` and is pinned by tests; the BEAM
  primitives are wrapped in a small `sqlode_ffi.erl` module.
  (#464)
- **BREAKING**: `query_analyzer.analysis_error_to_string` now
  takes a second `engine: model.Engine` argument so the rendered
  message is tailored to the configured engine. Placeholder
  references and cast-syntax hints both follow the engine's
  dialect:
  - PostgreSQL — `$N` references, `$N::int` cast suggestion
    (unchanged from before).
  - SQLite — `?N` references, `CAST(? AS INTEGER)` cast suggestion.
  - MySQL — `?N` references, `CAST(? AS SIGNED)` cast suggestion.

  Prior to this change every error referenced `$N` and suggested
  `$N::int` regardless of the engine, which produced parser errors
  in SQLite / MySQL when the user followed the hint as-is. Internal
  callers (`generate.gleam`, `verify.gleam`) are migrated; library
  consumers calling `analysis_error_to_string` directly need to add
  the engine argument. (#473)

### Fixed

- Generated `params.gleam` and `queries.gleam` no longer emit
  duplicate record fields, labelled arguments, or labelled
  constructor calls when one query references the same column
  twice (e.g. `WHERE x >= ? AND x < ?` for range scans). The
  second and later occurrences pick up a `_<n>` suffix
  (`x`, `x_2`, `x_3`, …) so the generated Gleam compiles.
  Single-occurrence params keep their original names; param order
  is preserved so placeholder binding stays correct. (#472)
- Generated `params.gleam` no longer imports the unused `None` /
  `Some` constructors from `gleam/option`; only `type Option` is
  pulled in (the rendered code only references the type itself).
  Generated `<engine>_adapter.gleam` now narrows its
  `gleam/option` import to what the file actually references —
  `{type Option}` when only nullable params/results force the
  type, and the full `{type Option, None, Some}` only when at
  least one query is `:one` / `:batchone` and the wrapper actually
  emits `Some(row) / None`. Downstream callers running with strict
  warnings (e.g. glinter `warnings_as_errors = true`, which sqlode
  itself uses) no longer have to suppress unused-import warnings on
  `// DO NOT EDIT` files. **Re-run `sqlode generate` to refresh
  existing `params.gleam` / `<engine>_adapter.gleam` files —
  previously generated copies still carry the broad import.**
  (#463)

## [0.8.0] - 2026-04-23

### Fixed

- **Placeholder syntax is validated per engine before analysis**
  (#459). `sqlode verify` / `generate` now reject placeholder styles
  that do not belong to the configured engine — MySQL `@name` /
  `:name` / `?N`, PostgreSQL `?` / `:name` / `$name`, etc. — with a
  diagnostic that names the offending token and lists the accepted
  forms. Previously the unsupported styles either survived into
  generated SQL unchanged or surfaced as late, misleading type
  inference errors.
- **Wrong-engine UPSERT tails are rejected at parse time** (#460).
  `ON DUPLICATE KEY UPDATE` under PostgreSQL / SQLite and
  `ON CONFLICT ... DO UPDATE / NOTHING` under MySQL now fail fast
  with a clear diagnostic, instead of being silently copied into
  the generated query. The emitted SQL can no longer disagree with
  the configured engine.
- **Sparse SQLite numbered placeholders are rejected** (#461).
  `?N` indices must now form a contiguous set starting at `?1`, so
  queries that write `?2` without `?1`, or skip from `?1` to `?3`,
  are caught before codegen. Previously the parser accepted them
  while emitting metadata (`param_count`, param layout) that did
  not honour the declared placeholder indices.

## [0.7.0] - 2026-04-23

### Changed

- **`verify` and `generate` share one post-parse validation path**
  (#441, #443). The duplicate-name / unsupported-annotation /
  array-engine / native-`:execresult` checks now live in a single
  `sqlode/query_validation` module so `sqlode verify` rejects every
  config `sqlode generate` would reject — the two commands can no
  longer drift. `verify` also flags normalized query-name collisions
  (e.g. `GetUser` and `get_user` both producing the same
  `get_user` / `GetUserParams` / `GetUserRow` identifiers) before
  codegen is allowed to emit duplicate Gleam declarations.
- **`.sql` path expansion shared across commands** (#440). Directory
  entries for `schema` / `queries` now expand through a shared
  `sqlode/sql_paths` helper, so `sqlode verify` accepts the same
  directory-based configs `sqlode generate` already supports and
  produces the same empty-directory diagnostics.
- **Release workflow runs glinter** (#442). The tag-driven
  `release.yml` build job now runs `gleam run -m glinter` alongside
  format / type-check / test / shellspec, matching `just all` and
  the PR CI contract. Release artifacts are now validated against
  the same quality bar contributors are asked to satisfy.

### Fixed

- **`ALTER TABLE ... ADD COLUMN IF NOT EXISTS`** (#448). The
  idempotency modifier is now stripped before the column definition
  is parsed, so PostgreSQL migrations that use the common
  `ADD COLUMN IF NOT EXISTS` (and `ADD IF NOT EXISTS`) forms apply
  cleanly instead of failing with a misleading
  `missing type for column if` error.
- **`ALTER COLUMN ... TYPE ... USING ...` no longer silently drifts**
  (#447). The new type extractor stops at the trailing `USING`
  cast clause so `TEXT → UUID USING id::uuid` parses, and a
  genuinely unrecognized type now surfaces a hard error instead of
  leaving the old type in the catalog without any diagnostic.
- **Raw-runtime decoders honor strong type mapping** (#445). Rich
  scalar decoders (`UUID` / `TIMESTAMP` / `DATE` / ...) are now
  wrapped as `decode.map(<primitive>, models.<Wrapper>)` so raw
  `queries.gleam` produces values the strong-mapped row types can
  consume. Previously the native adapter path wrapped correctly but
  the raw path decoded bare primitives, producing type-incompatible
  generated code.
- **`omit_unused_models` keeps strong / rich helpers for write-only
  queries** (#446). Param rich scalars are now collected separately
  from the catalog, so the `SqlUuid` / `SqlTimestamp` wrappers that
  an `:exec` query references still reach `models.gleam` even when
  pruning drops the underlying table. `params.gleam` and
  `queries.gleam` no longer reference types the generated project
  does not declare.
- **Non-local param types are always imported or qualified** (#444).
  Module-qualified custom types (`myapp/types.UserId`) referenced
  by `prepare_*` helpers now emit the matching selective import in
  `queries.gleam`, and rich scalars under `rich` / `strong` mapping
  are prefixed with `models.` everywhere outside `models.gleam`.
  The generated project compiles as written without user-written
  follow-up imports.

## [0.6.0] - 2026-04-21

### Added

- **First-class Docker distribution path** (#438). `Dockerfile`,
  `scripts/smoke_docker.sh`, and `.github/workflows/docker.yml` now
  build, smoke-test, and publish a container image for sqlode. Users
  can run the CLI via `ghcr.io/nao1215/sqlode` without installing
  Erlang/OTP on the host, and tagged releases publish semver image
  tags in addition to the escript artifact.
- **Tutorial-first SQLite onboarding** (#437).
  `doc/tutorials/getting-started-sqlite.md` now walks through install,
  `sqlode init`, `sqlode generate`, and a minimal `sqlight` runtime
  example end to end. The new `examples/sqlite-basic/` project is the
  runnable counterpart, and `spec/example_spec.sh` keeps the tutorial
  commands from drifting by asserting the generated modules exist.

### Changed

- **README install/reference cleanup**. The top-level README now points
  readers to the SQLite tutorial and runnable example first, documents
  the Docker install path alongside the existing release artifacts, and
  removes decorative callouts in favor of tighter reference prose.

### Fixed

- **`sqlode init --engine=mysql --runtime=native` now works** (#436).
  The stale CLI validation guard that still rejected MySQL native mode
  after v0.5.0 support shipped has been removed. Both Gleam tests and
  ShellSpec coverage now pin the generated config and starter schema
  for the MySQL native path.

## [0.5.0] - 2026-04-19

### Added

- **End-to-end MySQL support** (#417 epic; #418, #419, #420, #421,
  #422, #423). MySQL is now a first-class engine in both `raw` and
  `native` runtime modes. The native MySQL adapter targets the
  [`shork`](https://hexdocs.pm/shork/) Hex package. The previous
  config guard rejecting `engine: "mysql"` + `runtime: "native"` is
  gone.
- **Modifier-aware MySQL type contract** (#420). `TINYINT(1)` and
  `BOOLEAN` resolve to `BoolType`, `UNSIGNED` / `SIGNED` /
  `ZEROFILL` noise no longer blocks classification, and a new
  `DecimalType` keeps `DECIMAL` / `NUMERIC` columns lossless (a
  `String` Gleam type) instead of silently collapsing into `Float`.
  MySQL `SET(...)` columns are now first-class `SetType(name)` and
  surface as `List(<Name>Value)` in generated code with
  `_set_to_string` / `_set_from_string` helpers for the comma-joined
  wire format.
- **MySQL migration DDL** (#419). `ALTER TABLE ... MODIFY COLUMN`
  rewrites a column's type and nullability; `ALTER TABLE ... CHANGE
  COLUMN` renames and retypes in one step. Multi-file migration
  fixtures see the catalog from previously-parsed files, so an ALTER
  in `002_*.sql` can operate on a CREATE TABLE in `001_*.sql`.
  `AUTO_INCREMENT`, `ON UPDATE CURRENT_TIMESTAMP`, `CHARACTER SET`,
  `COLLATE`, `COMMENT`, and `VISIBLE`/`INVISIBLE` no longer bleed
  into column-type classification. Unsupported MySQL DDL now fails
  with an actionable `UnsupportedMysqlDdl` parse error instead of
  being silently dropped on the floor.
- **MySQL query parity fixtures** (#421). A dedicated MySQL advanced
  fixture pins the supported query subset: backtick-quoted
  identifiers, `LIMIT offset, count`, `INSERT ... ON DUPLICATE KEY
  UPDATE` (without phantom params from `VALUES(...)` references), CTE
  + JOIN result-column resolution, and `sqlode.slice` expansion
  through positional placeholders.
- **MySQL integration lanes** (#422). Three integration cases —
  `case_mysql_compile_raw`, `case_mysql_compile_native`, and
  `case_mysql_real` — exercise the generated MySQL adapter against
  pinned dependencies and a live MySQL 8.0 server. CI provisions
  MySQL alongside the existing PostgreSQL service. The live lane
  covers the full CRUD contract plus bytes / decimal / enum / SET
  round-trips.
- **Per-engine/runtime capability matrix** (#423).
  `doc/capabilities.md` now expresses support at engine/runtime
  granularity (raw/native flag plus the Hex driver each native
  adapter imports).
- **MySQL completeness follow-ups** (#430). Closes the gaps the #417
  epic had deferred:
  - `BLOB` / `BINARY` columns round-trip byte-for-byte in native
    mode via a private `@external(erlang, "shork_ffi", "coerce")`
    binding (`bit_array_to_shork`).
  - `SetType` is wired end-to-end through `params.gleam`,
    `queries.gleam`, and `mysql_adapter.gleam` — the new
    `common.qualified_field_type` helper prefixes generated enum /
    set types with `models.` in the consumer modules.
  - A new `<name>_default() -> <EnumType>` helper in `models.gleam`
    gives generated adapter / queries decoders a typed zero for
    `decode.failure`, so the case expression resolves as
    `Decoder(<EnumType>)` instead of `Decoder(String)`.
  - MySQL-native `:execresult` rejection is now pinned by a direct
    `generate_test` case; a positive raw-mode test covers the same
    query shape.
- **Glinter adoption** (#429). The project now runs
  [glinter](https://github.com/pairshaped/glinter) with
  `warnings_as_errors = true` via `just lint` / `just all` and a
  new CI step. 180+ `unnecessary_string_concatenation` findings
  were rewritten as multi-line literals; `discarded_result`,
  `short_variable_name`, `unqualified_import`, `redundant_case`,
  `missing_type_annotation`, and `assert_ok_pattern` violations
  are fixed (single inline `// nolint:` for the compile-time regex
  literals in `naming.new()`).

### Maintenance

- Dependabot version bumps replayed on top of the #417 main:
  `actions/upload-artifact` v4→v7 (#424),
  `actions/download-artifact` v4→v8 (#428),
  `softprops/action-gh-release` v2→v3 (#428).

## [0.4.0] - 2026-04-19

### Added

- **Engine-aware expression parser with MySQL clause preservation**
  (#405). `expr_parser.parse_stmt` / `parse_select_core` / `parse_expr`
  now accept a `model.Engine` argument. `InsertStmt` grows an
  `on_duplicate_key_update: List(Assignment)` field so MySQL
  `ON DUPLICATE KEY UPDATE` survives parsing as first-class IR instead
  of being silently skipped. MySQL's two-argument `LIMIT offset, count`
  form is now recognised and populates `offset` / `limit` in the
  expected order, while PostgreSQL's `LIMIT count OFFSET offset`
  semantics are preserved.
- **First-class MySQL `ENUM(...)` and `SET(...)` columns** (#407).
  Inline `ENUM` and `SET` column types on a MySQL `CREATE TABLE` no
  longer require a type override. `EnumDef` gains an `EnumKind`
  discriminator (`PostgresEnum | MySqlEnum | MySqlSet`). `ENUM`
  columns resolve to `EnumType(<table>_<column>)` and codegen emits
  the same Gleam sum type it has always emitted for PostgreSQL enums.
  `SET` columns resolve to `StringType` as a documented fallback,
  with the allowed values preserved on the catalog `EnumDef` for
  future consumers.
- **`sqlode init` creates missing parent directories** (#402). Running
  `sqlode init --output=./config/sqlode.yaml` used to fail with a
  generic write error when `config/` did not exist; the CLI now
  creates the parent directory and distinguishes directory-creation
  failures from file-write failures in diagnostics.
- **`just regen-capabilities` target** (#403). The capabilities
  snapshot test used to point contributors at a `gleam run -m
  sqlode/scripts/print_capabilities` entry point that did not exist;
  the script and just target are now real, and the failure message
  plus the tracked file header point at `just regen-capabilities`.

### Changed

- **Query analysis now consumes the expression-aware IR end-to-end**
  (#406). `analyze_query` parses the statement once via
  `expr_parser.parse_stmt` and drives parameter equality / `IN` /
  quantified inference from the rich `Expr` tree, plus table-scope
  (CTE / VALUES / derived / alias) extraction from `Stmt.ctes` and
  `SelectCore.from`. Token scanners remain as an explicit fallback
  only for `UnstructuredStmt` and for PostgreSQL / SQLite `ON
  CONFLICT` tails the IR does not yet model. Result: new parser
  features no longer need to be taught in parallel to several
  token scanners.
- **Generated-project compile checks are reproducible** (#404). The
  `spec/compile_spec.sh` harness now seeds each temporary Gleam
  project with a pinned `manifest.toml` copied from a checked-in
  `integration_test/warmup/` project. A new `just integration-prepare`
  target pre-populates the Hex cache and is the single explicit
  online step `just all` requires; `just integration-refresh` refreshes
  the committed pins. `CONTRIBUTING.md` documents the online/offline
  contract.

### Fixed

- None.

## [0.3.0] - 2026-04-18

### Added

- **`sqlode verify` command**: A static verification lane that walks
  every SQL block listed in the config, runs the full schema /
  strict-views / query / analyzer pipeline, and reports every finding
  without writing files. Exits non-zero when any finding is present,
  suitable as a CI gate before `sqlode generate`. The new
  `query_parameter_limit` config option (mirroring sqlc's setting of
  the same name) becomes the first enforced policy — queries whose
  inferred parameter count exceeds the limit produce a finding.
- **Function-first `prepare_<query>` helpers**: Every generated query
  now emits a `prepare_<function_name>(...)` helper that takes the
  params record fields as positional arguments and returns the
  `#(sql, values)` tuple Gleam database drivers consume directly.
  Call sites can now use `queries.prepare_get_author(id: 1)` instead
  of manually composing a query descriptor, a params record, and
  `runtime.prepare`. The low-level descriptor API is preserved for
  batching, caching, or custom wrappers.
- **Expression-aware SQL IR**: Replaced the thin statement IR with a
  normalised IR (`Stmt` / `SelectCore` / `CteDef` / `Expr`) covering
  CTEs, LATERAL, select items, predicates, arithmetic, CASE,
  functions, casts, `IN`, `EXISTS`, `ANY` / `ALL`, window specs, and
  RETURNING. Type inference now operates on the IR instead of
  reverse-engineering semantics from raw token slices, and
  `col = ANY(placeholder)` / sibling quantified patterns now
  participate in parameter inference alongside `IN`. LATERAL subquery
  aliases are treated as nullable when the surrounding join is
  `LEFT [OUTER] JOIN LATERAL`. Four executable fixtures under
  `test/fixtures/complex_sql_*.sql` pin the new behaviour.

### Changed

- **`strict_views: true` is now the default**. A configuration that
  omits `strict_views` previously warned and continued with a partial
  catalog, letting a generated model silently drift away from the
  real database shape. Generation now fails with a `SchemaParseError`
  when a view references an unknown column. Set `strict_views: false`
  to restore the legacy permissive behaviour for schemas that still
  need it.
- RETURNING resolution is now scoped to the DML target table, so
  `INSERT .. SELECT .. RETURNING` no longer sees CTE / SELECT source
  tables as ambiguous candidates.
- The schema parser now accepts non-reserved keywords (`action`,
  `name`, `order`, …) as column identifiers.

### Fixed

- **Ambiguous unqualified parameter columns are now rejected.**
  Parameter inference previously swallowed ambiguity from
  `context.find_column_in_tables` and fell back to the primary
  table, so `WHERE id = $1` in a multi-table query silently bound the
  param type to whichever table came first. Unqualified predicate
  columns that match more than one in-scope table now raise
  `AmbiguousColumnName`. The token scan's FROM scope is also
  restricted to the outermost statement via
  `token_utils.strip_leading_with`, so CTE-internal tables no longer
  leak into the ambiguity check for the outer predicate.

## [0.2.1] - 2026-04-18

### Fixed

- Raw decoder for embedded columns (e.g., `sqlode.embed(table)`) now
  correctly constructs the nested type (e.g., `Author(id:, name:, bio:)`)
  instead of flattening all fields into the outer row constructor.

## [0.2.0] - 2026-04-18

### Added

- **Destructive DDL support**: The schema parser now applies `DROP TABLE`,
  `DROP VIEW`, `DROP TYPE`, `ALTER TABLE ... DROP COLUMN`,
  `ALTER TABLE ... RENAME TO` / `RENAME COLUMN`,
  `ALTER TABLE ... ALTER COLUMN TYPE` / `SET NOT NULL` / `DROP NOT NULL`
  to the catalog. Full migration histories with destructive DDL can now
  be processed without consolidating into a snapshot.
- **Ambiguous column detection**: `find_column_in_tables` now errors when
  a bare column name matches in two or more tables, instead of silently
  picking the first match. Use a table qualifier (e.g., `table.column`)
  to resolve the ambiguity.
- **IR-based column inference**: The column inferencer now uses the
  structured IR (`SelectStatement.select_items`, `from`, `joins`) for
  simple SELECT queries, reducing reliance on token-level heuristics.
  Compound queries (UNION/EXCEPT) and `sqlode.embed()` fall back to the
  existing token-based path.
- **Raw decoder generation**: `queries.gleam` now generates standalone
  `*_decoder()` functions for `:one` / `:many` queries in raw mode,
  providing type-safe `decode.Decoder(models.Row)` values without
  requiring a native adapter.

### Fixed

- `sqlode.embed(TABLE)` is now rewritten into a concrete qualified
  column list in the emitted SQL. Previously the literal
  `sqlode.embed(...)` text leaked into generated runtime queries, which
  the database rejected as invalid SQL. Embed detection during column
  inference is also now case-insensitive.
- Table qualifier in `table.column` patterns was silently discarded in
  `resolve_column_type_from_tokens` and
  `resolve_column_type_nullable_from_tokens`, causing lookups to search
  all tables instead of the specified one.
- `sqlc-compatibility.md` incorrectly stated that batch annotations and
  `sqlc.*` prefix were implemented. Updated to reflect actual status.

### Changed

- `UnsupportedStatement` schema parse error removed. Destructive DDL
  statements are now applied rather than rejected.
- README updated to clarify that sqlode is not a drop-in sqlc
  replacement and uses the `sqlode.*` macro prefix exclusively.

## [0.1.0] - 2026-04-13

### Added

- Initial sqlc-style code generator for Gleam
- PostgreSQL, MySQL, and SQLite engine support
- Query annotations `:one`, `:many`, `:exec`, `:execresult`, `:execrows`, `:execlastid` supported end-to-end. `:batchone`, `:batchmany`, `:batchexec`, and `:copyfrom` are parsed for sqlc compatibility but currently fail generation with an unsupported-annotation error.
- sqlode macros: `sqlode.arg`, `sqlode.narg`, `sqlode.slice`, `sqlode.embed`
- Type mapping for INT, FLOAT, BOOL, TEXT, BYTEA, UUID, JSON, TIMESTAMP, DATE, TIME
- PostgreSQL ENUM type support
- Nullable column detection with `Option(T)` wrapping
- Result record types (`models.gleam`) for `:one` and `:many` queries
- Adapter generation for pog (PostgreSQL) and sqlight (SQLite)
- RETURNING clause support for INSERT/UPDATE/DELETE
- CTE (WITH clause) support
- JOIN type inference
- Type overrides and column renames via config
- `init` command with stub `db/schema.sql` and `db/query.sql` creation
- `generate` command with `--config` flag
- Version constant in `version.gleam` as single source of truth
