#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
acceptance_data=$(mktemp -d)
acceptance_port=${PDF_TOOLS_ACCEPTANCE_PORT:-3211}
binary=${PDF_TOOLS_ACCEPTANCE_BINARY:-${CARGO_TARGET_DIR:-target}/release/pdf-tools-server}
PDF_TOOLS_DATA_DIR="$acceptance_data" PORT="$acceptance_port" PDF_TOOLS_BIND_ADDRESS=127.0.0.1 "$binary" >"$acceptance_data/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; rm -rf "$acceptance_data"' EXIT INT TERM
for attempt in $(seq 1 100); do
  if curl --fail --silent "http://127.0.0.1:$acceptance_port/health" >/dev/null; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$acceptance_data/server.log"; exit 1; fi
  sleep .1
done
browser_options=()
if [ -n "${PDF_TOOLS_ACCEPTANCE_CHECKS:-}" ]; then browser_options+=(--checks "$PDF_TOOLS_ACCEPTANCE_CHECKS"); fi
python3 scripts/elm-browser-acceptance.py --url "http://127.0.0.1:$acceptance_port" --output "${PDF_TOOLS_ACCEPTANCE_OUTPUT:-/tmp/pdf-elm-acceptance}" "${browser_options[@]}"
python3 scripts/workflow-regressions.py --url "http://127.0.0.1:$acceptance_port" --output "${PDF_TOOLS_ACCEPTANCE_OUTPUT:-/tmp/pdf-elm-acceptance}/workflows"
python3 scripts/elm-http-acceptance.py --port "$acceptance_port"
