#!/bin/sh
# Smoke-test a sqlode container image end-to-end. Ensures the image
# can run `version`, scaffold a fresh project with `init`, and
# generate typed Gleam code from the scaffolded SQL. Used by the
# release workflow and re-usable locally:
#
#   ./scripts/smoke_docker.sh sqlode:test

set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <image-tag>" >&2
  exit 1
fi

IMAGE="$1"

TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

# `version` must print the canonical banner.
OUTPUT="$(docker run --rm "$IMAGE" version)"
case "$OUTPUT" in
  *"sqlode v"*) ;;
  *)
    echo "version command did not emit expected banner: $OUTPUT" >&2
    exit 1
    ;;
esac

# `--help` must succeed.
docker run --rm "$IMAGE" --help >/dev/null

# `init` must scaffold sqlode.yaml + stub SQL files in a bind-mounted
# working directory. Use the host UID so the generated files are not
# owned by root.
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$TMP_DIR:/work" \
  "$IMAGE" init --engine=sqlite --runtime=native >/dev/null

test -f "$TMP_DIR/sqlode.yaml"
test -f "$TMP_DIR/db/schema.sql"
test -f "$TMP_DIR/db/query.sql"

# `generate` must produce the expected Gleam modules.
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$TMP_DIR:/work" \
  "$IMAGE" generate >/dev/null

test -f "$TMP_DIR/src/db/params.gleam"
test -f "$TMP_DIR/src/db/queries.gleam"
test -f "$TMP_DIR/src/db/models.gleam"
test -f "$TMP_DIR/src/db/sqlight_adapter.gleam"

echo "Smoke test passed: $IMAGE"
