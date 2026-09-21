#!/bin/sh

set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"

# SQLODE_BIN points the suite at a packaged escript (the file attached
# to a GitHub Release or baked into the Docker image) instead of the
# erlang-shipment, so the CLI contract is checked on what users run.
if [ -n "${SQLODE_BIN:-}" ]; then
  exec escript "$SQLODE_BIN" "$@"
fi

exec "$PROJECT_ROOT/build/erlang-shipment/entrypoint.sh" run "$@"
