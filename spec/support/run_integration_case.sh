#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: run_integration_case.sh <case_fn> <integration_tmp_base>" >&2
  exit 2
fi

CASE_FN="$1"
INTEGRATION_TMP_BASE="$2"
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"

export INTEGRATION_TMP_BASE
export PROJECT_ROOT

# shellcheck source=integration_test/lib.sh
. "$PROJECT_ROOT/integration_test/lib.sh"
# shellcheck source=integration_test/runner.sh
. "$PROJECT_ROOT/integration_test/runner.sh"
# shellcheck source=integration_test/cases.sh
. "$PROJECT_ROOT/integration_test/cases.sh"

"$CASE_FN"
