#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm ci --prefix frontend
scripts/generate-elm.sh
npm run build --prefix frontend
cargo build --locked --bin pdf-tools-server
export PORT="${PORT:-3200}"
export PDF_TOOLS_BIND_ADDRESS="${PDF_TOOLS_BIND_ADDRESS:-127.0.0.1}"
# Serve all assets and APIs from Axum. Rebuild changed Elm/CSS/bridge files;
# ordinary reload picks up the new versioned bundle.
node frontend/watch.mjs &
watch_pid=$!
trap 'kill "$watch_pid" 2>/dev/null || true' EXIT INT TERM
cargo run --locked --bin pdf-tools-server
