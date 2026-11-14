#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build
mkdir -p build/HeatBar.app/Contents/MacOS
target="$(uname -m)-apple-macos14.0"
swiftc -O -target "$target" -parse-as-library -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement -o build/HeatBar.app/Contents/MacOS/HeatBar HeatBar.swift
swiftc -O -target "$target" -framework Metal -framework MetalPerformanceShaders -framework Foundation -o build/HeatBar.app/Contents/MacOS/heat-worker heat-worker.swift
cat > build/HeatBar.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.giovannirco.heatbar</string>
  <key>CFBundleName</key><string>HeatBar</string>
  <key>CFBundleDisplayName</key><string>HeatBar</string>
  <key>CFBundleExecutable</key><string>HeatBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --deep --sign - build/HeatBar.app
