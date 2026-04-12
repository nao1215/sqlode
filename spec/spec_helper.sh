#!/bin/sh
# shellcheck shell=sh

set -eu

export PATH="/home/nao/.local/share/mise/installs/gleam/1.15.2:/home/nao/.local/share/mise/installs/erlang/28.4.1/bin:/home/nao/.local/share/mise/installs/rebar/3.27.0/bin:$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

PROJECT_ROOT="$(cd "$SHELLSPEC_SPECDIR/.." && pwd)"
export PROJECT_ROOT

TEST_OUTPUT_DIR="$PROJECT_ROOT/test_output"
export TEST_OUTPUT_DIR

generate() {
  cd "$PROJECT_ROOT" && gleam run -- generate "$@" 2>&1
}

clean_test_output() {
  rm -rf "$TEST_OUTPUT_DIR"
}
