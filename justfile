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

shellspec:
  shellspec

# Pre-populate the shared Hex cache used by `spec/compile_spec.sh` and
# the `integration_test/` harness. This is the one step that requires
# network access; once it has run successfully, each compile-spec case
# uses pinned versions from `integration_test/warmup/manifest.toml` and
# no further Hex resolution is needed.
integration-prepare:
  cd integration_test/warmup && gleam deps download

# Refresh `integration_test/warmup/manifest.toml` by re-resolving the
# latest versions allowed by its `gleam.toml`. Run and commit the
# updated manifest when bumping the integration dependency pins.
integration-refresh:
  rm -f integration_test/warmup/manifest.toml
  cd integration_test/warmup && gleam deps download

regen-capabilities:
  gleam build
  gleam run -m sqlode/scripts/print_capabilities > doc/capabilities.md

all:
  gleam format --check src/ test/
  gleam check
  gleam build --warnings-as-errors
  gleam run -m glinter
  gleam test
  just test-javascript
  just integration-prepare
  shellspec
