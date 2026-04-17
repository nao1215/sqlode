#!/bin/sh
# Iterate over the declarative case registry in cases.sh and run each
# case through the shared harness in runner.sh.

set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT

INTEGRATION_TMP_BASE="${INTEGRATION_TMP_BASE:-$PROJECT_ROOT/test_integration_tmp}"
export INTEGRATION_TMP_BASE

# shellcheck source=integration_test/lib.sh
. "$PROJECT_ROOT/integration_test/lib.sh"
# shellcheck source=integration_test/runner.sh
. "$PROJECT_ROOT/integration_test/runner.sh"
# shellcheck source=integration_test/cases.sh
. "$PROJECT_ROOT/integration_test/cases.sh"

cleanup() {
  rm -rf "$INTEGRATION_TMP_BASE"
}
trap cleanup EXIT

echo "=== Running integration tests ==="

# Allow callers to focus on a subset: `run.sh case_sqlite_basic`. With no
# arguments, iterate over the whole registry declared in cases.sh.
if [ $# -gt 0 ]; then
  for case_fn in "$@"; do
    "$case_fn"
  done
else
  for case_fn in $ALL_INTEGRATION_CASES; do
    "$case_fn"
  done
fi

echo ""
echo "=== Integration tests passed ==="
