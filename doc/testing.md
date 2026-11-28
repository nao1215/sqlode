# Testing

`just all` runs the checks below that need no database: format, type check, build, glinter, the unit tests on Erlang, the JavaScript runtime tests and the atago suites. CI runs the unit tests on the Gleam floor (1.14.0, OTP 27) and on the latest Gleam 1.x (OTP 29).

## Examples and unit tests

`gleam test` runs the gleeunit suite under `test/`. Each pipeline stage has its own file: `lexer_test.gleam`, `schema_parser_test.gleam`, `query_parser_test.gleam`, `query_analyzer_test.gleam`, `codegen_test.gleam`, `generate_test.gleam` and `verify_test.gleam`. `sqlc_compat_test.gleam` runs SQL written for sqlc. `codegen_test.gleam` also checks that the code shown in the README is what `generate` writes. Each fixed bug keeps its reproduction in the file of the stage it broke, or in a `test/regression_*_test.gleam` file.

## Generated properties

`test/sqlode_metamon_test.gleam` uses metamon for the runtime value encoders (round trips, array length), the checked placeholder and slice markers (accept positive indices, reject zero and negatives, never share a prefix) and the naming helpers over random identifiers (`to_snake_case`, `to_pascal_case`, `normalize_identifier` and `singularize` are idempotent and drop separators).

## Metamorphic relations

`test/analysis_metamorphic_test.gleam` rewrites the query files of 17 fixture pairs (PostgreSQL, MySQL and SQLite) in ways that must not change what the generated code depends on, and checks that every query keeps its command, parameters (index, name, type, nullability) and result columns:

- different whitespace between tokens: spaces, tabs and line breaks, drawn by metamon,
- a `--` comment at the end of each line, containing a quote and a placeholder,
- upper-case and lower-case SQL keywords,
- the queries of a file in a random order.

String literals, quoted identifiers and the `-- name:` lines are never rewritten.

## Snapshots

`test/snapshot_test.gleam` uses birdie for the files `generate` writes: PostgreSQL, MySQL and SQLite with the native adapters, PostgreSQL with the raw runtime for the README queries, and SQLite with every query command. A snapshot holds every file of one sql block before the CLI runs `gleam format`, so it does not depend on the formatter of the Gleam on PATH. Review a changed snapshot with `gleam run -m birdie` before accepting it; the accepted files live in `test/birdie_snapshots/`.

## Differential testing against SQLite

`scripts/differential_sqlite.py` compares sqlode's analysis of the SQLite fixtures with SQLite itself. `test/sqlite_oracle_dump.gleam` prints, for each query, the SQL the generated code sends, the number of values it binds and the result columns it decodes. The script prepares and runs that SQL on an empty in-memory database built from the schema, with Python's standard `sqlite3` module, inside a savepoint that is rolled back, and fails when SQLite expects a different number of parameters, returns other columns or another column order, or accepts a query sqlode rejects. `test/fixtures/sqlite_differential_query.sql` holds the shapes that are easy to get wrong: a named parameter used twice, numbered `?1` reused, `SELECT *` over a join, scalar and correlated subqueries, CTEs, `UNION ALL`, `RETURNING`, `LIMIT ? OFFSET ?` and `IN (?, ?, ?)`. CI runs it in the `All checks` job (`python3 scripts/differential_sqlite.py` locally, from the repository root).

## End-to-end tests

`spec/cli.atago.yaml` runs the CLI (`init`, `generate`, `verify`, flags, exit codes, stdout and stderr) with atago. CI runs it on the Erlang shipment and again on the escript attached to each release (`SQLODE_BIN`). `spec/integration.atago.yaml` generates code into temporary Gleam projects under `integration_test/` and builds and tests them.

The `snapshot of ...` scenarios at the end of `spec/cli.atago.yaml` pin whole outputs to the files in `spec/snapshots/`: the top-level help, the help of every subcommand and a `verify` report with several findings. atago normalises the temporary paths. After an intended change, refresh them with `PROJECT_ROOT=$PWD atago snapshot update --parallel 1 --filter "snapshot of" spec/cli.atago.yaml` and review the diff.

## Real databases

The `All checks` job runs `integration_test/run.sh` against PostgreSQL 18 (service container) and the runner's MySQL 8, and the `atago E2E integration` job runs `spec/integration.atago.yaml`, the SQLite cases (`integration_test/cases.sh`) with sqlight. The generated adapters execute their queries there, so a type or decoder that does not match what the database returns fails the run.

## Paired CI benchmarks

`bench/himorime.yaml` measures the escript (`version`, `generate` on 10 and 1000 queries, `verify` on 1000 queries, and a failing `generate`). `.github/workflows/bench.yml` runs `himorime ci` on each pull request, which measures the base revision and the head in the same job. `bench/README.md` lists what is measured and what is not.

## Coverage

`just coverage` (`gleam build --target erlang`, then `gleam run -m metamon/mutation -- coverage`) runs the tests on the Erlang target with every module under `src/` measured and writes `build/coverage/lcov.info`; `.github/workflows/coverage.yml` reports it with octocov on pull requests and main. The coverage command needs Gleam 1.19 or later, which is newer than the build floor in `gleam.toml`. The local run on 2026-11-28 reached 82.8% of the lines.

## Mutation testing

`.github/workflows/mutation.yml` runs `gleam run -m metamon/mutation`, which changes one operator, `!` or boolean literal at a time in a copy of the project and runs `gleam test` after each change. A mutant the suite still passes (a survivor) points at a branch no test pins down. Pull requests and pushes mutate the modules they change, and the weekly run mutates every module (about 880 mutants). The job fails on a survivor that `doc/mutation/baseline.json` does not list.

The baseline comes from the first full run on CI (2026-11-27, run 46040862787). To record a new one, download the `mutation-results` artifact of a weekly run to `build/mutation/results.json` and run `just mutation-record`, which also rewrites the table below. `just mutation` runs every module locally; a loaded machine can time out tests that pass on CI, so record the baseline from a CI run.

<!-- mutation:start -->
| Module | Killed | Lived | Timed out | Score |
|---|---:|---:|---:|---:|
| `sqlode` | 0 | 2 | 0 | 0.0% |
| `sqlode/cli` | 4 | 5 | 0 | 44.4% |
| `sqlode/internal/capabilities` | 6 | 0 | 0 | 100.0% |
| `sqlode/internal/char_utils` | 62 | 36 | 0 | 63.3% |
| `sqlode/internal/codegen/adapter` | 10 | 4 | 0 | 71.4% |
| `sqlode/internal/codegen/common` | 6 | 7 | 0 | 46.2% |
| `sqlode/internal/codegen/models` | 7 | 4 | 0 | 63.6% |
| `sqlode/internal/codegen/params` | 3 | 4 | 0 | 42.9% |
| `sqlode/internal/codegen/queries` | 8 | 2 | 0 | 80.0% |
| `sqlode/internal/config` | 3 | 5 | 0 | 37.5% |
| `sqlode/internal/generate` | 21 | 6 | 0 | 77.8% |
| `sqlode/internal/lexer` | 25 | 3 | 0 | 89.3% |
| `sqlode/internal/model` | 14 | 0 | 0 | 100.0% |
| `sqlode/internal/naming` | 8 | 4 | 0 | 66.7% |
| `sqlode/internal/query_analyzer` | 8 | 3 | 0 | 72.7% |
| `sqlode/internal/query_analyzer/column_inferencer` | 49 | 79 | 0 | 38.3% |
| `sqlode/internal/query_analyzer/context` | 1 | 0 | 0 | 100.0% |
| `sqlode/internal/query_analyzer/embed_rewriter` | 2 | 1 | 0 | 66.7% |
| `sqlode/internal/query_analyzer/expr_parser` | 4 | 58 | 0 | 6.5% |
| `sqlode/internal/query_analyzer/param_inferencer` | 6 | 9 | 0 | 40.0% |
| `sqlode/internal/query_analyzer/placeholder` | 5 | 5 | 0 | 50.0% |
| `sqlode/internal/query_analyzer/token_utils` | 27 | 51 | 0 | 34.6% |
| `sqlode/internal/query_analyzer/type_inference` | 16 | 18 | 0 | 47.1% |
| `sqlode/internal/query_parser` | 16 | 7 | 0 | 69.6% |
| `sqlode/internal/query_validation` | 8 | 3 | 0 | 72.7% |
| `sqlode/internal/schema_parser` | 35 | 13 | 0 | 72.9% |
| `sqlode/internal/type_mapping` | 3 | 0 | 0 | 100.0% |
| `sqlode/internal/verify` | 0 | 3 | 0 | 0.0% |
| `sqlode/runtime` | 8 | 0 | 0 | 100.0% |
| all | 365 | 332 | 0 | 52.4% |
<!-- mutation:end -->

## Nightly runs

`.github/workflows/nightly-property.yml` runs the whole suite twenty times with `METAMON_RUNS_MULTIPLIER=5`, each pass with a new seed. A failure report prints its seed, so the case can be replayed with `metamon.forall_with(metamon.Config(..metamon.default_config(), seed: Some(seed)), ...)` and kept as a regression test.
