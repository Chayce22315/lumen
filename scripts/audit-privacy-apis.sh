#!/usr/bin/env bash
# Lists calls to APIs that Apple's privacy manifest requires a reason for, so
# App/*/PrivacyInfo.xcprivacy can be kept truthful. Exits 1 when any are found.
#
#   scripts/audit-privacy-apis.sh
#
# Categories (https://developer.apple.com/documentation/bundleresources/privacy-manifest-files):
# file timestamps, system boot time, disk space, active keyboards, user defaults.
set -euo pipefail
cd "$(dirname "$0")/.."

pattern='UserDefaults|NSUserDefaults|creationDate|modificationDate|contentModificationDate|fileModificationDate|attributesOfItem|attributesOfFileSystem|systemUptime|mach_absolute_time|volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|systemSize|activeInputModes|statfs|getattrlist|\bstat\('

if hits=$(grep -rnE "$pattern" --include=*.swift App Packages/LumenKit/Sources Packages/LumenInterface/Sources); then
  echo "Required-reason API calls found; declare them in App/*/PrivacyInfo.xcprivacy:"
  echo "$hits"
  exit 1
fi
echo "No required-reason API calls in the app's sources."
