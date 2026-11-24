#!/usr/bin/env python3
"""Refreshes the generated counts in FILE_STRUCTURE.md from the repository tree.

    python3 scripts/update-file-structure.py

Updates the Files/Tests columns of the module tables, the totals line and the detailed tree.
Module descriptions are written by hand and kept as they are; a module missing from a table is
reported so its row can be added.
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DOC = os.path.join(ROOT, "FILE_STRUCTURE.md")
PACKAGES = ("Packages/LumenKit", "Packages/LumenInterface")
APP_TARGETS = ("App/Lumen", "App/LumenWidgets", "App/LumenUITests")


def swift_files(directory: str, recursive: bool = True) -> int:
    path = os.path.join(ROOT, directory)
    if not os.path.isdir(path):
        return 0
    if not recursive:
        return sum(1 for name in os.listdir(path) if name.endswith(".swift"))
    return sum(1 for _, _, names in os.walk(path) for name in names if name.endswith(".swift"))


def detailed_tree() -> list[str]:
    lines = []
    for package in PACKAGES:
        for kind in ("Sources", "Tests"):
            base = os.path.join(ROOT, package, kind)
            if not os.path.isdir(base):
                continue
            for directory, _, names in sorted(os.walk(base)):
                count = sum(1 for name in names if name.endswith(".swift"))
                if count:
                    relative = os.path.relpath(directory, ROOT)
                    lines.append(f"{relative}/  ({count})")
    return lines


def main() -> int:
    with open(DOC, encoding="utf-8") as handle:
        text = handle.read()

    seen: set[str] = set()

    def row(match: re.Match[str]) -> str:
        module, description = match.group(1), match.group(2)
        package = next((p for p in PACKAGES if os.path.isdir(os.path.join(ROOT, p, "Sources", module))), None)
        if package is None:
            return match.group(0)
        seen.add(module)
        files = swift_files(f"{package}/Sources/{module}")
        tests_dir = f"{package}/Tests/{module}Tests"
        tests = str(swift_files(tests_dir)) if os.path.isdir(os.path.join(ROOT, tests_dir)) else "—"
        return f"| `{module}` | {description} | {files} | {tests} |"

    text = re.sub(r"^\| `(\w+)` \| (.+?) \| [\d—]+ \| [\d—]+ \|$", row, text, flags=re.M)

    sources = sum(swift_files(f"{p}/Sources") for p in PACKAGES)
    tests = sum(swift_files(f"{p}/Tests") for p in PACKAGES)
    apps = sum(swift_files(t) for t in APP_TARGETS)
    text, totals = re.subn(
        r"^\*\*Totals:\*\* .*$",
        f"**Totals:** {sources} source files and {tests} test files in the packages, plus {apps} in the "
        "app targets (app, widget, UI tests).",
        text,
        flags=re.M,
    )
    tree = "\n".join(detailed_tree())
    text, trees = re.subn(r"(## Detailed tree\n\n```\n)(.*?)(\n```)", lambda m: m.group(1) + tree + m.group(3), text, flags=re.S)
    if totals != 1 or trees != 1:
        sys.exit("FILE_STRUCTURE.md no longer has the expected totals line and detailed tree block")

    for package in PACKAGES:
        for module in sorted(os.listdir(os.path.join(ROOT, package, "Sources"))):
            if module not in seen and swift_files(f"{package}/Sources/{module}"):
                print(f"warning: {module} has no row in FILE_STRUCTURE.md", file=sys.stderr)

    with open(DOC, "w", encoding="utf-8") as handle:
        handle.write(text)
    print(f"Updated FILE_STRUCTURE.md: {sources} sources, {tests} tests, {apps} app target files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
