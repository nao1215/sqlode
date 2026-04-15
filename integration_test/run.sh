#!/bin/sh

set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

echo "=== Running integration tests ==="

bash "$PROJECT_ROOT/integration_test/compile_test.sh"
bash "$PROJECT_ROOT/integration_test/sqlite_test.sh"
bash "$PROJECT_ROOT/integration_test/sqlite_extended_test.sh"
bash "$PROJECT_ROOT/integration_test/sqlite_advanced_test.sh"

echo "=== Integration tests passed ==="
