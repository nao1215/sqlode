#!/bin/sh
# shellcheck shell=sh
#
# Declarative registry of integration test cases. Each case is a function
# that calls `run_integration_case` (defined in `runner.sh`) with the
# per-scenario parameters. Adding a new case is a single function block
# and one entry in `ALL_INTEGRATION_CASES`.
#
# Expected environment:
#   PROJECT_ROOT — absolute path to the sqlode checkout
#   INTEGRATION_TMP_BASE — directory under which per-case temp trees live
#     (default: $PROJECT_ROOT/test_integration_tmp).
#
# Parameter reference for run_integration_case:
#   label         Human-readable name printed in section headers.
#   project_name  gleam.toml `name`. Must be a valid Gleam project name.
#   engine        postgresql | sqlite | mysql.
#   runtime       raw | native.
#   schema        Absolute path to the schema SQL fixture.
#   queries       Absolute path to the queries SQL fixture.
#   expected_files Space-separated list of files under src/db/ that must exist
#                  after `sqlode generate`.
#   dev_deps      Optional: `gleeunit` or a verbatim TOML snippet.
#   test_module_src   Optional: tracked .gleam test module to copy into
#                     $INTEGRATION_DIR/test/ before building.
#   test_module_name  Required when test_module_src is set — the filename to
#                     write it as (the gleam test runner module name).

case_compile_raw() {
  run_integration_case \
    label="raw mode" \
    project_name="integration_compile_raw" \
    engine="postgresql" \
    runtime="raw" \
    schema="$PROJECT_ROOT/test/fixtures/schema.sql" \
    queries="$PROJECT_ROOT/test/fixtures/query.sql" \
    expected_files="params.gleam queries.gleam models.gleam"
}

case_compile_complex() {
  run_integration_case \
    label="raw mode with complex schema" \
    project_name="integration_compile_complex" \
    engine="postgresql" \
    runtime="raw" \
    schema="$PROJECT_ROOT/test/fixtures/complex_schema.sql" \
    queries="$PROJECT_ROOT/test/fixtures/complex_query.sql" \
    expected_files="params.gleam queries.gleam models.gleam"
}

case_compile_all_types() {
  run_integration_case \
    label="raw mode with all types" \
    project_name="integration_compile_all_types" \
    engine="postgresql" \
    runtime="raw" \
    schema="$PROJECT_ROOT/test/fixtures/all_types_schema.sql" \
    queries="$PROJECT_ROOT/test/fixtures/all_types_query.sql" \
    expected_files="params.gleam queries.gleam models.gleam"
}

case_sqlite_basic() {
  run_integration_case \
    label="SQLite real database" \
    project_name="sqlite_integration_test" \
    engine="sqlite" \
    runtime="native" \
    schema="$PROJECT_ROOT/test/fixtures/sqlite_schema.sql" \
    queries="$PROJECT_ROOT/test/fixtures/sqlite_crud_query.sql" \
    dev_deps="gleeunit" \
    expected_files="params.gleam queries.gleam models.gleam sqlight_adapter.gleam" \
    test_module_src="$PROJECT_ROOT/integration_test/fixtures/sqlite_basic_test.gleam" \
    test_module_name="sqlite_integration_test_test.gleam"
}

case_sqlite_extended() {
  run_integration_case \
    label="SQLite extended features" \
    project_name="sqlite_extended_test" \
    engine="sqlite" \
    runtime="native" \
    schema="$PROJECT_ROOT/test/fixtures/sqlite_extended_schema.sql" \
    queries="$PROJECT_ROOT/test/fixtures/sqlite_extended_query.sql" \
    dev_deps="gleeunit" \
    expected_files="params.gleam queries.gleam models.gleam sqlight_adapter.gleam" \
    test_module_src="$PROJECT_ROOT/integration_test/fixtures/sqlite_extended_test.gleam" \
    test_module_name="sqlite_extended_test_test.gleam"
}

case_sqlite_advanced() {
  run_integration_case \
    label="SQLite advanced features" \
    project_name="sqlite_advanced_test" \
    engine="sqlite" \
    runtime="native" \
    schema="$PROJECT_ROOT/test/fixtures/sqlite_advanced_schema.sql" \
    queries="$PROJECT_ROOT/test/fixtures/sqlite_advanced_query.sql" \
    dev_deps="gleeunit" \
    expected_files="params.gleam queries.gleam models.gleam sqlight_adapter.gleam" \
    test_module_src="$PROJECT_ROOT/integration_test/fixtures/sqlite_advanced_test.gleam" \
    test_module_name="sqlite_advanced_test_test.gleam"
}

# Requires a running PostgreSQL server reachable through $DATABASE_URL.
# Not included in ALL_INTEGRATION_CASES because most local runs do not
# have Postgres available; invoke explicitly:
#
#   DATABASE_URL=postgresql://postgres:postgres@localhost:5432/sqlode_test \
#     sh integration_test/run.sh case_postgresql_real
#
# In CI, `.github/workflows/ci.yml` provisions a postgres service
# container and runs this case with DATABASE_URL pointing at it. The
# gleeunit test module itself checks DATABASE_URL at startup and
# prints a skip message if it is missing, so the case still exits 0
# when executed without Postgres available (e.g. in a local "all
# integration cases" run that accidentally picks it up).
case_postgresql_real() {
  run_integration_case \
    label="PostgreSQL real database" \
    project_name="postgresql_real_test" \
    engine="postgresql" \
    runtime="native" \
    schema="$PROJECT_ROOT/test/fixtures/postgresql_schema.sql" \
    queries="$PROJECT_ROOT/test/fixtures/postgresql_crud_query.sql" \
    dev_deps="gleeunit+envoy" \
    expected_files="params.gleam queries.gleam models.gleam pog_adapter.gleam" \
    test_module_src="$PROJECT_ROOT/integration_test/fixtures/postgresql_real_test.gleam" \
    test_module_name="postgresql_real_test_test.gleam"
}

# Every case listed here runs by default in `run.sh` without arguments.
# `case_postgresql_real` is intentionally excluded because it needs a
# live Postgres; pass it explicitly to `run.sh` when DATABASE_URL is set.
ALL_INTEGRATION_CASES="
  case_compile_raw
  case_compile_complex
  case_compile_all_types
  case_sqlite_basic
  case_sqlite_extended
  case_sqlite_advanced
"
