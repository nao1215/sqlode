set shell := ["sh", "-cu"]

default:
  @just --list

deps:
  gleam deps download

format:
  gleam format src/ test/

format-check:
  gleam format --check src/ test/

check:
  gleam check

build:
  gleam build --warnings-as-errors

test:
  gleam test

# JavaScript-target runtime tests. Mirrors the `Build (JavaScript)`
# job in CI / release.yml. Uses a hand-rolled entry point because
# gleeunit's JavaScript auto-discovery transitively pulls in `glint`,
# whose generated JavaScript fails to parse on Node — see
# `test/sqlode_js_test.gleam`.
test-javascript:
  gleam build --target javascript
  gleam run -m sqlode_js_test --target javascript

# Run the glinter (https://github.com/pairshaped/glinter) static
# analysis. Configuration lives under `[tools.glinter]` in
# `gleam.toml`; with `warnings_as_errors = true` set there, this task
# fails the build on any unsuppressed warning.
lint:
  gleam run -m glinter

e2e:
  PROJECT_ROOT="$PWD" atago run --parallel 1 ./spec

# Compare sqlode's analysis of the SQLite fixtures with SQLite itself
# (Python 3 with the standard sqlite3 module)
differential:
  python3 scripts/differential_sqlite.py

# Measure the sqlode escript with the himorime suite in bench/ (requires himorime on PATH)
bench:
  himorime run bench

# Compare main with the working tree on the himorime suite (BASE=main)
bench-compare:
  himorime compare --against ${BASE:-main} bench

# Pre-populate the shared Hex cache used by the atago suite under
# `spec/` and the `integration_test/` harness. This is the one step
# that requires network access; once it has run successfully, each
# generated-project case uses pinned versions from
# `integration_test/warmup/manifest.toml` and no further Hex
# resolution is needed.
integration-prepare:
  cd integration_test/warmup && gleam deps download

# Refresh `integration_test/warmup/manifest.toml` by re-resolving the
# latest versions allowed by its `gleam.toml`. Run and commit the
# updated manifest when bumping the integration dependency pins.
integration-refresh:
  rm -f integration_test/warmup/manifest.toml
  cd integration_test/warmup && gleam deps download

# Mutation testing of every module, failing on survivors the baseline lacks.
# Slow (about 880 mutants): CI runs it weekly.
mutation workers="8":
  gleam run -m metamon/mutation -- run --workers {{workers}}
  gleam run -m metamon/mutation -- gate

# Record build/mutation/results.json as the baseline and refresh doc/testing.md
mutation-record:
  gleam run -m metamon/mutation -- baseline

# Line coverage of the Erlang test run and the atago CLI suite, written to
# build/coverage/lcov.info (requires atago on PATH)
coverage:
  gleam build --target erlang
  gleam run -m metamon/mutation -- coverage --e2e 'PROJECT_ROOT="$PWD" SQLODE_BIN="$METAMON_COVERAGE_ESCRIPT" atago run --ci --parallel 1 ./spec/cli.atago.yaml'

regen-capabilities:
  gleam build
  gleam run -m print_capabilities > doc/capabilities.md

all:
  gleam format --check src/ test/
  gleam check
  gleam build --warnings-as-errors
  gleam run -m glinter
  gleam test
  just differential
  just test-javascript
  just integration-prepare
  just e2e
