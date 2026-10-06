#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm ci --prefix frontend
cargo fmt --all --check
cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
cargo test --locked --workspace --all-features
cargo doc --locked --workspace --all-features --no-deps
scripts/generate-elm.sh --check
npm run format:check --prefix frontend
npm test --prefix frontend
node --check frontend/bridge.js
npm run build --prefix frontend
cargo build --locked --release --bin pdf-tools-server
# Launch the actual release server with isolated persistent data. Python tests
# generate small fixtures and inspect downloads as well as rendered controls.
scripts/acceptance.sh
