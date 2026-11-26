#!/bin/bash
# Builds a genuinely UNSIGNED MJ-Wallpaper.ipa. Requires macOS + Xcode (free) + XcodeGen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
rm -rf build Payload MJ-Wallpaper.ipa
xcodebuild -project MJWallpaper.xcodeproj -scheme MJWallpaper -configuration Release \
  -sdk iphoneos -arch arm64 -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
APP="build/Build/Products/Release-iphoneos/MJWallpaper.app"
mkdir Payload && cp -R "$APP" Payload/
# unsigned: make sure no signature / provisioning profile slipped in
rm -rf Payload/MJWallpaper.app/_CodeSignature Payload/MJWallpaper.app/embedded.mobileprovision
zip -qry MJ-Wallpaper.ipa Payload
echo "--- IPA structure check"
unzip -l MJ-Wallpaper.ipa | grep -E "Payload/MJWallpaper.app/(MJWallpaper|Info.plist|Video-B-anim.tendies)"
unzip -l MJ-Wallpaper.ipa | grep -E "_CodeSignature|embedded.mobileprovision" && { echo "FAIL: signature present"; exit 1; } || echo "OK: no signature / no provisioning profile"
file Payload/MJWallpaper.app/MJWallpaper
ls -l MJ-Wallpaper.ipa
