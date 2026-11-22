#!/usr/bin/env bash
# Runs the XCUITest smoke tests (App/LumenUITests) on an iOS Simulator.
#
#   scripts/ios-ui-tests.sh                 # newest available iPhone simulator
#   LUMEN_SIMULATOR=<udid> scripts/ios-ui-tests.sh
#
# Needs Xcode 16 or newer. Output goes to build/ui-tests.log and build/UITests.xcresult.
set -euo pipefail

cd "$(dirname "$0")/.."

udid="${LUMEN_SIMULATOR:-}"
if [[ -z "$udid" ]]; then
  udid="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    if version < (18, 0):
        continue
    for device in entries:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            key = (version, device["name"])
            if best is None or key > best[0]:
                best = (key, device["udid"])
if best is None:
    sys.exit("No available iPhone simulator with iOS 18 or newer")
print(best[1])
')"
fi
echo "Simulator: $(xcrun simctl list devices | grep "$udid" | sed -e 's/^ *//')"

mkdir -p build
rm -rf build/UITests.xcresult
status=0
xcodebuild \
  -project Lumen.xcodeproj \
  -scheme Lumen \
  -destination "id=$udid" \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  -resultBundlePath build/UITests.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  test > build/ui-tests.log 2>&1 || status=$?

grep -E "Test Case .* (passed|failed)|error: |Executed [0-9]+ test" build/ui-tests.log | sort -u || true
if [[ $status -ne 0 ]]; then
  echo "xcodebuild test failed with status $status; last lines of build/ui-tests.log:"
  tail -60 build/ui-tests.log
  exit "$status"
fi
