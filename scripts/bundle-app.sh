#!/usr/bin/env bash
# Assembles build/Kite.app: the app, precompiled shaders, and (when
# scripts/fetch-cef.sh has run) the Chromium framework plus its helper apps.
# Usage: scripts/bundle-app.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
cd "$ROOT"

swift build -c "$CONFIG" --product Kite
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/Kite.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Shaders" "$CONTENTS/Frameworks"
cp "$BIN/Kite" "$CONTENTS/MacOS/Kite"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Sources/KiteMac/Shaders/*.metal "$CONTENTS/Resources/Shaders/"

# Precompiled shaders mean no Metal compile at launch. Falls back to runtime
# compilation if the Metal toolchain isn't installed.
if xcrun -sdk macosx metal -c Sources/KiteMac/Shaders/Kite.metal -o "$ROOT/build/Kite.air" 2>/dev/null; then
    xcrun -sdk macosx metallib "$ROOT/build/Kite.air" -o "$CONTENTS/Resources/Kite.metallib"
    rm -f "$ROOT/build/Kite.air"
else
    echo "note: Metal toolchain missing, shaders will compile at launch (xcodebuild -downloadComponent MetalToolchain)"
fi

CEF="$ROOT/ThirdParty/cef"
if [[ -d "$CEF/Release/Chromium Embedded Framework.framework" ]]; then
    swift build -c "$CONFIG" --product KiteHelper
    cp -R "$CEF/Release/Chromium Embedded Framework.framework" "$CONTENTS/Frameworks/"
    # Chromium launches each process type from its own helper bundle.
    for kind in "" "GPU" "Renderer" "Plugin" "Alerts"; do
        name="Kite Helper${kind:+ ($kind)}"
        id="dev.gabek.Kite.helper${kind:+.$(echo "$kind" | tr '[:upper:]' '[:lower:]')}"
        helper="$CONTENTS/Frameworks/$name.app/Contents"
        mkdir -p "$helper/MacOS"
        cp "$BIN/KiteHelper" "$helper/MacOS/$name"
        sed -e "s/__NAME__/$name/g" -e "s/__ID__/$id/g" Resources/Helper-Info.plist > "$helper/Info.plist"
    done
else
    echo "note: no CEF in ThirdParty/cef, building a WebKit-only app (run scripts/fetch-cef.sh for Chromium)"
fi

# Ad-hoc signature, inside out, so the helpers and framework load.
for helper in "$CONTENTS/Frameworks/"*.app; do
    [[ -e "$helper" ]] && codesign --force --sign - "$helper"
done
if [[ -d "$CONTENTS/Frameworks/Chromium Embedded Framework.framework" ]]; then
    codesign --force --sign - "$CONTENTS/Frameworks/Chromium Embedded Framework.framework"
fi
codesign --force --sign - "$APP"
echo "Built $APP"
