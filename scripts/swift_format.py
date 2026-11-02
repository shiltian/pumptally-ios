#!/usr/bin/env python3
"""Run Xcode's formatter on changed Swift lines, leaving untouched code alone."""
import argparse
import difflib
import re
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--base", default="HEAD")
parser.add_argument("--fix", action="store_true")
args = parser.parse_args()
base = args.base
if not base or set(base) == {"0"}:
    base = subprocess.check_output(["git", "hash-object", "-t", "tree", "/dev/null"], text=True).strip()

tracked = subprocess.check_output(
    ["git", "diff", "--name-only", "--diff-filter=ACMR", "-z", base, "--", "*.swift"]
).decode().split("\0")
untracked = subprocess.check_output(
    ["git", "ls-files", "--others", "--exclude-standard", "-z", "--", "*.swift"]
).decode().split("\0")
failed = False
for filename in sorted(set(tracked + untracked) - {""}):
    # Preserve upstream formatting in pinned, vendored dependencies.
    if Path(filename).parts[0] == "ThirdParty":
        continue
    if not Path(filename).is_file():
        continue
    diff = subprocess.check_output(
        ["git", "diff", "--no-ext-diff", "--no-color", "--unified=0", base, "--", filename], text=True
    )
    command = ["xcrun", "swift-format", "format", "--configuration", ".swift-format"]
    if filename not in untracked:
        ranges = re.findall(r"^@@ .*?\+(\d+)(?:,(\d+))? @@", diff, re.MULTILINE)
        ranges = [(int(start), int(count or "1")) for start, count in ranges if count != "0"]
        if not ranges:
            continue
        for start, count in ranges:
            command += ["--lines", f"{start}:{start + count - 1}"]
    result = subprocess.run(command + [filename], capture_output=True, text=True)
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        failed = True
        continue
    source = Path(filename).read_text()
    if result.stdout == source:
        continue
    if args.fix:
        Path(filename).write_text(result.stdout)
    else:
        print("".join(difflib.unified_diff(source.splitlines(keepends=True), result.stdout.splitlines(keepends=True),
                                         fromfile=filename, tofile=filename + " (swift-format)")), end="")
        failed = True
raise SystemExit(int(failed))
