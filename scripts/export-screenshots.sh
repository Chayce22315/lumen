#!/usr/bin/env bash
# Copies the screenshots taken by LumenScreenshotTests out of a test result bundle as
# <name>.png files.
#
#   scripts/export-screenshots.sh [build/UITests.xcresult] [build/screenshots]
#
# Needs Xcode 16 or newer (xcresulttool export attachments).
set -euo pipefail
cd "$(dirname "$0")/.."

result="${1:-build/UITests.xcresult}"
output="${2:-build/screenshots}"
raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT

xcrun xcresulttool export attachments --path "$result" --output-path "$raw"
mkdir -p "$output"
python3 - "$raw" "$output" <<'PY'
import json, os, shutil, sys

raw, output = sys.argv[1], sys.argv[2]
with open(os.path.join(raw, "manifest.json"), encoding="utf-8") as handle:
    manifest = json.load(handle)

copied = 0

def visit(node):
    global copied
    if isinstance(node, dict):
        exported, name = node.get("exportedFileName"), node.get("suggestedHumanReadableName")
        if exported and name and exported.lower().endswith(".png"):
            # Names look like "01-Home_0_<uuid>.png"; keep the step name.
            step = name.split("_", 1)[0]
            shutil.copyfile(os.path.join(raw, exported), os.path.join(output, f"{step}.png"))
            copied += 1
        for value in node.values():
            visit(value)
    elif isinstance(node, list):
        for value in node:
            visit(value)

visit(manifest)
if copied == 0:
    sys.exit("No screenshots in the result bundle; did LumenScreenshotTests run?")
print(f"Exported {copied} screenshots to {output}")
PY
