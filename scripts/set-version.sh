#!/usr/bin/env bash
# Sets the marketing version and build number every target uses (App/Configuration/Lumen.xcconfig).
#
#   scripts/set-version.sh 1.0.0        # version 1.0.0, build number + 1
#   scripts/set-version.sh 1.0.0 42     # version 1.0.0, build 42
set -euo pipefail
cd "$(dirname "$0")/.."

config=App/Configuration/Lumen.xcconfig
version="${1:?usage: scripts/set-version.sh <version> [build]}"
if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "Version must look like 1.2 or 1.2.3"; exit 1
fi
current_build=$(sed -nE 's/^CURRENT_PROJECT_VERSION = ([0-9]+)$/\1/p' "$config")
if [[ -z "$current_build" ]]; then
  echo "CURRENT_PROJECT_VERSION not found in $config"; exit 1
fi
build="${2:-$((current_build + 1))}"
if ! [[ "$build" =~ ^[0-9]+$ ]]; then
  echo "Build number must be a whole number"; exit 1
fi
sed -i.bak -E "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $version/; s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $build/" "$config"
rm -f "$config.bak"
echo "Version $version ($build)"
