#!/bin/sh
# shellcheck shell=sh
#
# Generic per-case runner used by `run.sh`. Sourced on top of `lib.sh` so
# all the bootstrap primitives are already available.
#
# Each case invokes `run_integration_case key=value ...`. Required keys:
# label, project_name, engine, runtime, schema, queries, expected_files.
# Optional keys: dev_deps, test_module_src, test_module_name.
#
# A case without test_module_src builds the generated project; with it,
# the runner also copies the test module into $INTEGRATION_DIR/test/
# and runs `gleam test`. In both paths the expected files are verified
# between `sqlode generate` and the build step.

run_integration_case() {
  _ic_label=""
  _ic_project_name=""
  _ic_engine=""
  _ic_runtime=""
  _ic_schema=""
  _ic_queries=""
  _ic_dev_deps=""
  _ic_expected_files=""
  _ic_test_module_src=""
  _ic_test_module_name=""

  for arg in "$@"; do
    case "$arg" in
      label=*) _ic_label="${arg#*=}" ;;
      project_name=*) _ic_project_name="${arg#*=}" ;;
      engine=*) _ic_engine="${arg#*=}" ;;
      runtime=*) _ic_runtime="${arg#*=}" ;;
      schema=*) _ic_schema="${arg#*=}" ;;
      queries=*) _ic_queries="${arg#*=}" ;;
      dev_deps=*) _ic_dev_deps="${arg#*=}" ;;
      expected_files=*) _ic_expected_files="${arg#*=}" ;;
      test_module_src=*) _ic_test_module_src="${arg#*=}" ;;
      test_module_name=*) _ic_test_module_name="${arg#*=}" ;;
      *)
        echo "run_integration_case: unknown key: $arg" >&2
        return 2
        ;;
    esac
  done

  if [ -z "$_ic_label" ] || [ -z "$_ic_project_name" ] \
     || [ -z "$_ic_engine" ] || [ -z "$_ic_runtime" ] \
     || [ -z "$_ic_schema" ] || [ -z "$_ic_queries" ] \
     || [ -z "$_ic_expected_files" ]; then
    echo "run_integration_case: label, project_name, engine, runtime, schema, queries, and expected_files are required" >&2
    return 2
  fi

  if [ -n "$_ic_test_module_src" ] && [ -z "$_ic_test_module_name" ]; then
    echo "run_integration_case: test_module_name is required when test_module_src is set" >&2
    return 2
  fi

  _ic_dir="$INTEGRATION_TMP_BASE/$_ic_project_name"

  echo ""
  echo "--- $_ic_label ---"

  integration_clean "$_ic_dir"

  write_project_args="--dir $_ic_dir --name $_ic_project_name --engine $_ic_engine --runtime $_ic_runtime --schema $_ic_schema --queries $_ic_queries"
  if [ -n "$_ic_dev_deps" ]; then
    write_project_args="$write_project_args --dev-deps $_ic_dev_deps"
  fi

  # Intentional word-splitting: pass each key/value as its own positional
  # argument to integration_write_project.
  # shellcheck disable=SC2086
  integration_write_project $write_project_args

  if [ -n "$_ic_test_module_src" ]; then
    mkdir -p "$_ic_dir/test"
  fi

  echo "Generating code..."
  integration_generate "$_ic_dir"

  for f in $_ic_expected_files; do
    if [ ! -f "$_ic_dir/src/db/$f" ]; then
      echo "FAIL: expected file $f not generated" >&2
      return 1
    fi
  done

  if [ -n "$_ic_test_module_src" ]; then
    cp "$_ic_test_module_src" "$_ic_dir/test/$_ic_test_module_name"
    echo "Building and running tests..."
    integration_build "$_ic_dir"
    integration_test "$_ic_dir"
  else
    echo "Building generated project..."
    integration_build "$_ic_dir"
  fi

  echo "PASS: $_ic_label"
}
