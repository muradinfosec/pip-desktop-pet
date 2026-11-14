#!/bin/zsh
# Builds Pip's desktop app from source into ~/Applications/Pip.app.
# Needs Apple's Command Line Tools (for swiftc): xcode-select --install
set -euo pipefail

here=${0:A:h}/src
app="$HOME/Applications/Pip.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Pip needs Apple's Command Line Tools to build. Install them with: xcode-select --install" >&2
  exit 1
fi

# Quit a running copy so the new one replaces it.
pkill -f "Pip.app/Contents/MacOS/Pip" 2>/dev/null || true

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Pip.app/Contents/MacOS"

cat > "$work/Pip.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pip</string>
  <key>CFBundleIdentifier</key><string>local.pip-pet.desktop</string>
  <key>CFBundleExecutable</key><string>Pip</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Pip listens when you press Control-Option-P so you can talk to it.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Pip turns what you say into text so it can answer you.</string>
</dict>
</plist>
PLIST

swiftc -O "$here/main.swift" "$here/Agent.swift" "$here/Sessions.swift" -o "$work/Pip.app/Contents/MacOS/Pip" \
  -framework Cocoa -framework WebKit -framework Speech -framework AVFoundation -framework Carbon -framework ServiceManagement
mkdir -p "$work/Pip.app/Contents/Resources"
cp "$here/pet.html" "$work/Pip.app/Contents/Resources/pet.html"
if [[ -f "$here/AppIcon.icns" ]]; then cp "$here/AppIcon.icns" "$work/Pip.app/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - "$work/Pip.app"

mkdir -p "$HOME/Applications"
rm -rf "$app"
mv "$work/Pip.app" "$app"
echo "Built $app"
