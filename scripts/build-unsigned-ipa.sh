#!/usr/bin/env bash
# Builds Lumen in the Release configuration for real devices without signing, and packages it as
# build/Lumen-unsigned.ipa. Proves the device/Release build compiles (CI runs it) and gives an
# archive that free re-signing tools can install on your own iPhone. No Apple account needed.
#
#   scripts/build-unsigned-ipa.sh
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
status=0
xcodebuild \
  -project Lumen.xcodeproj \
  -scheme Lumen \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData-Release \
  CODE_SIGNING_ALLOWED=NO \
  build > build/release-build.log 2>&1 || status=$?
if [[ $status -ne 0 ]] || ! grep -q "BUILD SUCCEEDED" build/release-build.log; then
  echo "Release device build failed:"
  grep -E "error:" build/release-build.log | sort -u | head -100 || true
  tail -30 build/release-build.log
  exit 1
fi

app="build/DerivedData-Release/Build/Products/Release-iphoneos/Lumen.app"
if [[ ! -d "$app" ]]; then
  echo "Expected $app after the build"; exit 1
fi
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Payload"
cp -R "$app" "$staging/Payload/"
rm -f build/Lumen-unsigned.ipa
(cd "$staging" && zip -qry "$OLDPWD/build/Lumen-unsigned.ipa" Payload)
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Info.plist")
echo "Built build/Lumen-unsigned.ipa (version $version, build $build, $(du -h build/Lumen-unsigned.ipa | cut -f1))"
