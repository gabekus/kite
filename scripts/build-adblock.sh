#!/usr/bin/env bash
# Builds the ad blocker (Sources/KiteAdblock/rust, Brave's adblock-rust behind a C API)
# into Sources/KiteAdblock/rust/target/lib/libkite_adblock.a and regenerates its header.
# Optional, like CEF: without it Kite builds and runs with no ad blocking.
# Needs Rust (rustup) and, to regenerate the header, `cargo install cbindgen`.
# Usage: scripts/build-adblock.sh [--universal]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/Sources/KiteAdblock/rust"
export PATH="$HOME/.cargo/bin:$PATH"
cd "$CRATE"

# Match the deployment target in Package.swift so the linker doesn't warn.
export MACOSX_DEPLOYMENT_TARGET=14.0
OUT="$CRATE/target/lib"
mkdir -p "$OUT"
if [[ "${1:-}" == "--universal" ]]; then
    cargo build --release --target aarch64-apple-darwin --target x86_64-apple-darwin
    lipo -create target/aarch64-apple-darwin/release/libkite_adblock.a \
        target/x86_64-apple-darwin/release/libkite_adblock.a -output "$OUT/libkite_adblock.a"
else
    cargo build --release
    cp target/release/libkite_adblock.a "$OUT/libkite_adblock.a"
fi

if command -v cbindgen >/dev/null; then
    cbindgen --quiet --config cbindgen.toml --output "$ROOT/Sources/KiteAdblock/include/kite_adblock.h"
fi
echo "Built $OUT/libkite_adblock.a"
