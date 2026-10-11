#!/bin/zsh
# Builds Vox.app (release, Apple Silicon) and installs it to /Applications.
# Signs with your Apple Development certificate when present so macOS remembers the
# Microphone / Accessibility / Input Monitoring permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
APP=build/Vox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Vox "$APP/Contents/MacOS/Vox"
# SwiftPM resource bundles (FluidAudio ships some) must sit next to the executable's bundle resources.
for b in .build/arm64-apple-macosx/release/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Liquid Glass icon (Icon Composer) → Assets.car + AppIcon.icns fallback.
# Absolute paths: actool runs through a shared daemon that resolves relative paths against *its* working directory.
xcrun actool --compile "$PWD/$APP/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 \
  --app-icon AppIcon --output-partial-info-plist "$PWD/build/actool-partial.plist" "$PWD/Resources/AppIcon.icon" > /dev/null

IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -oE '"(Apple Development|Developer ID Application)[^"]+"' | tr -d '"' || true)
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --deep --options runtime --entitlements Resources/Vox.entitlements --sign "$IDENTITY" "$APP"
else
  echo "No signing identity found; ad-hoc signing (you'll need to re-grant permissions after each rebuild)"
  codesign --force --deep --entitlements Resources/Vox.entitlements --sign - "$APP"
fi

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x Vox 2>/dev/null || true
  rm -rf /Applications/Vox.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Vox.app"
fi
