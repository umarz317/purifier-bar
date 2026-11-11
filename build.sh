#!/bin/bash
# Builds "Purifier Bar.app" into ./build. Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Purifier Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" Resources
if [[ ! -f Resources/AppIcon.icns ]]; then
    swiftc Sources/Logo.swift Tools/make-icon/main.swift -o build/make-icon
    build/make-icon Resources/AppIcon.icns
fi
swiftc -O -parse-as-library -target arm64-apple-macos14 Sources/*.swift -o "$APP/Contents/MacOS/PurifierBar"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# A real certificate keeps the signature stable, so macOS remembers Local Network access across rebuilds.
# Override with SIGN_IDENTITY="Apple Development: ..." ; falls back to ad-hoc ("-").
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)}"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x PurifierBar || true
    pkill -x MiPurifier || true  # earlier names
    pkill -x AirBar || true
    rm -rf /Applications/AirBar.app "/Applications/Mi Purifier.app" "/Applications/Purifier Bar.app"
    cp -R "$APP" /Applications/
    open "/Applications/Purifier Bar.app"
fi
echo "Built $APP"
