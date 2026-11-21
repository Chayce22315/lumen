#!/usr/bin/env bash
# Runs a SwiftPM command for Packages/LumenKit inside the pinned Linux toolchain container.
#
#   scripts/lumenkit-linux.sh build
#   scripts/lumenkit-linux.sh test
#   scripts/lumenkit-linux.sh test --filter LumenOrganizationTests
#
# Linux builds use a separate scratch path so they never clobber Xcode/macOS build products.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${LUMEN_LINUX_IMAGE:-lumen-swift:6.2}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -t "$IMAGE" "$ROOT/Tools/LinuxToolchain"
fi

if [ "$#" -eq 0 ]; then
  set -- test
fi

subcommand="$1"
shift

exec docker run --rm \
  -v "$ROOT:/workspace" \
  -w /workspace/Packages/LumenKit \
  "$IMAGE" \
  swift "$subcommand" --scratch-path /workspace/.build-linux "$@"
