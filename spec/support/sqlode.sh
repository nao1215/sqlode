#!/bin/sh

set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"

exec "$PROJECT_ROOT/build/erlang-shipment/entrypoint.sh" run "$@"
