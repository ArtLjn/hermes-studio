#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
swift build --configuration release
binary_dir="$(swift build --configuration release --show-bin-path)"
app_name="$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' macOS/Info.plist)"
app="$PWD/dist/$app_name.app"
mkdir -p -- "$app/Contents/MacOS" "$app/Contents/Resources"
cp -- macOS/Info.plist "$app/Contents/Info.plist"
cp -- macOS/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -- "$binary_dir/HermesStudio" "$app/Contents/MacOS/HermesStudio"
cp -- Sources/HermesStudio/Resources/app-logo.png "$app/Contents/Resources/app-logo.png"
rm -f -- "$app/Contents/Resources/desk-at-dusk.jpg"
mkdir -p -- "$app/Contents/Resources/Avatars"
cp -- Sources/HermesStudio/Resources/Avatars/*.jpg "$app/Contents/Resources/Avatars/"
/usr/bin/codesign --force --sign - "$app"
printf '%s\n' "$app"
