#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <escript-path>" >&2
  exit 1
fi

case "$1" in
  /*) BINARY="$1" ;;
  *) BINARY="$(pwd)/$1" ;;
esac

chmod +x "$BINARY"

TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

"$BINARY" --help >/dev/null
"$BINARY" generate --help >/dev/null

(
  cd "$TMP_DIR"

  "$BINARY" init --output=sqlode.yaml >/dev/null

  test -f sqlode.yaml
  test -f db/schema.sql
  test -f db/query.sql

  "$BINARY" generate --config=sqlode.yaml >/dev/null

  test -f src/db/params.gleam
  test -f src/db/queries.gleam
  test -f src/db/models.gleam
)

echo "Smoke test passed: $BINARY"
