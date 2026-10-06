#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary=$(mktemp --suffix=.elm)
trap 'rm -f "$temporary"' EXIT
cargo run --locked --quiet --features elm-codegen --bin generate-elm > "$temporary"
frontend/node_modules/.bin/elm-format "$temporary" --yes >/dev/null
if [ "${1:-}" = --check ]; then
  diff -u frontend/elm/Api/Generated.elm "$temporary"
else
  cp "$temporary" frontend/elm/Api/Generated.elm
fi

cargo run --locked --quiet --features elm-codegen --bin generate-elm -- --fixtures > "$temporary"
frontend/node_modules/.bin/elm-format "$temporary" --yes >/dev/null
if [ "${1:-}" = --check ]; then
  diff -u frontend/tests/RustWire.elm "$temporary"
else
  cp "$temporary" frontend/tests/RustWire.elm
fi
