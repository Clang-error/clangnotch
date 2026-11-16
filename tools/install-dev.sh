#!/bin/bash
# Builds Debug and puts it in /Applications: quits only the installed instance (by pid, other
# copies keep running), copies the build over without re-signing, launches it, and removes the
# DerivedData copy so Spotlight lists the app once. Nothing is touched if the build fails.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

xcodebuild -project ClangNotch.xcodeproj -scheme ClangNotch -configuration Debug build -quiet
products=$(xcodebuild -project ClangNotch.xcodeproj -scheme ClangNotch -configuration Debug -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
app="$products/ClangNotch.app"
[ -x "$app/Contents/MacOS/ClangNotch" ] || { echo "No build product at $app" >&2; exit 1; }

target=/Applications/ClangNotch.app
pid=$(pgrep -f "^$target/Contents/MacOS/ClangNotch" || true)
if [ -n "$pid" ]; then
    kill "$pid"
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
fi
rm -rf "$target"
cp -R "$app" "$target"
open "$target"
rm -rf "$app"
mdimport "$target"
sleep 1
echo "Installed $(defaults read "$target/Contents/Info.plist" CFBundleShortVersionString) (build $(defaults read "$target/Contents/Info.plist" CFBundleVersion)), pid $(pgrep -f "^$target/Contents/MacOS/ClangNotch" || echo '?')"
