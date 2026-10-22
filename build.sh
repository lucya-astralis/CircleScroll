#!/bin/zsh
# Baut CircleScroll.app (universal: arm64 + x86_64) in ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/CircleScroll.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" Sources/*.swift -o "build/CircleScroll-$arch"
done
lipo -create build/CircleScroll-arm64 build/CircleScroll-x86_64 -output "$APP/Contents/MacOS/CircleScroll"
rm build/CircleScroll-arm64 build/CircleScroll-x86_64

codesign --force --sign - "$APP"
echo "Fertig: $APP"
