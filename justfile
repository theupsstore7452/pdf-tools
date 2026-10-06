default:
    @just --list

dev:
    scripts/dev.sh

generate-api:
    scripts/generate-elm.sh

check:
    scripts/check.sh

fmt:
    cargo fmt --all
    cd frontend && npm run format

lint:
    cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
    cd frontend && npm run format:check

test:
    cargo test --locked --workspace --all-features
    cd frontend && npm test

build:
    cargo build --locked --bin pdf-tools-server
    cd frontend && npm ci && npm run build

release:
    cargo build --release --locked --bin pdf-tools-server
    cd frontend && npm ci && npm run build

clean:
    cargo clean
    rm -rf frontend/dist frontend/elm-stuff
