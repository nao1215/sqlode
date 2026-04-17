#!/bin/sh
# shellcheck shell=sh
#
# Shared integration-project scaffolding used by both `spec/compile_spec.sh`
# (ShellSpec) and the per-scenario scripts in `integration_test/`.
#
# Callers are expected to export $PROJECT_ROOT before sourcing this file.
# Each helper is idempotent; they operate on the directory passed in and
# never read or write the outer shell's pwd.
#
# Example:
#   PROJECT_ROOT=/path/to/sqlode
#   . "$PROJECT_ROOT/integration_test/lib.sh"
#
#   integration_clean "$INTEGRATION_DIR"
#   integration_write_project \
#     --dir "$INTEGRATION_DIR" \
#     --name my_case \
#     --engine sqlite \
#     --runtime native \
#     --schema "$PROJECT_ROOT/test/fixtures/sqlite_schema.sql" \
#     --queries "$PROJECT_ROOT/test/fixtures/sqlite_crud_query.sql" \
#     --dev-deps gleeunit
#   integration_generate "$INTEGRATION_DIR"
#   integration_build "$INTEGRATION_DIR"

integration_clean() {
  rm -rf "$1"
}

integration_write_project() {
  dir=""
  name="integration_test"
  engine=""
  runtime=""
  schema=""
  queries=""
  dev_deps=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --engine) engine="$2"; shift 2 ;;
      --runtime) runtime="$2"; shift 2 ;;
      --schema) schema="$2"; shift 2 ;;
      --queries) queries="$2"; shift 2 ;;
      --dev-deps) dev_deps="$2"; shift 2 ;;
      *)
        echo "integration_write_project: unknown arg: $1" >&2
        return 2
        ;;
    esac
  done

  if [ -z "$dir" ] || [ -z "$engine" ] || [ -z "$runtime" ] \
     || [ -z "$schema" ] || [ -z "$queries" ]; then
    echo "integration_write_project: --dir, --engine, --runtime, --schema, --queries are required" >&2
    return 2
  fi

  mkdir -p "$dir/src/db"
  _integration_write_gleam_toml "$dir" "$name" "$engine" "$runtime" "$dev_deps"
  _integration_write_sqlode_yaml "$dir" "$schema" "$queries" "$engine" "$runtime"
}

_integration_driver_dep() {
  # Args: runtime engine
  case "$1:$2" in
    native:postgresql) printf 'pog = ">= 4.0.0 and < 5.0.0"\n' ;;
    native:sqlite) printf 'sqlight = ">= 1.0.0 and < 2.0.0"\n' ;;
    *) printf '' ;;
  esac
}

_integration_dev_deps_block() {
  case "$1" in
    "") return 0 ;;
    gleeunit)
      printf '\n[dev-dependencies]\ngleeunit = ">= 1.0.0 and < 2.0.0"\n'
      ;;
    gleeunit+envoy)
      printf '\n[dev-dependencies]\ngleeunit = ">= 1.0.0 and < 2.0.0"\nenvoy = ">= 1.0.0 and < 2.0.0"\n'
      ;;
    *)
      # Passed through verbatim as an entry list separated by newlines.
      printf '\n[dev-dependencies]\n%s\n' "$1"
      ;;
  esac
}

_integration_write_gleam_toml() {
  dir="$1"
  name="$2"
  engine="$3"
  runtime="$4"
  dev_deps="$5"

  driver_line=$(_integration_driver_dep "$runtime" "$engine")
  dev_section=$(_integration_dev_deps_block "$dev_deps")

  {
    printf 'name = "%s"\n' "$name"
    printf 'version = "0.1.0"\n'
    printf 'target = "erlang"\n'
    printf '\n'
    printf '[dependencies]\n'
    printf 'gleam_stdlib = ">= 0.44.0 and < 2.0.0"\n'
    if [ -n "$driver_line" ]; then
      # driver_line already carries a trailing newline when emitted by
      # _integration_driver_dep, but command substitution strips it, so
      # print the value and re-add a newline to keep the next entry on
      # a fresh line.
      printf '%s\n' "$driver_line"
    fi
    printf 'sqlode = { path = "%s" }\n' "$PROJECT_ROOT"
    if [ -n "$dev_section" ]; then
      printf '%s\n' "$dev_section"
    fi
  } > "$dir/gleam.toml"
}

_integration_write_sqlode_yaml() {
  dir="$1"
  schema="$2"
  queries="$3"
  engine="$4"
  runtime="$5"

  cat > "$dir/sqlode.yaml" <<YAML
version: "2"
sql:
  - schema: "$schema"
    queries: "$queries"
    engine: "$engine"
    gen:
      gleam:
        out: "$dir/src/db"
        runtime: "$runtime"
YAML
}

integration_generate() {
  (cd "$PROJECT_ROOT" && gleam run -- generate --config="$1/sqlode.yaml")
}

integration_build() {
  (cd "$1" && gleam build)
}

integration_test() {
  (cd "$1" && gleam test)
}
