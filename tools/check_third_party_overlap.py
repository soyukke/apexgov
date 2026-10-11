#!/usr/bin/env python3
"""Guard against third-party code being copied into unit tests.

Compares the Apex source embedded in Zig `test` blocks (multi-line `\\\\` strings)
with every Apex file under the local, git-ignored fixture directory and fails
when a test shares several identical lines with those files.

usage: python3 tools/check_third_party_overlap.py [--root DIR] [--min-len N] [--max-lines N]

Exits 0 when no test exceeds the limit (or when the fixture directory is absent).
"""

import argparse
import os
import re
import subprocess
import sys


def normalize(line):
    return re.sub(r"\s+", " ", line.strip())


def load_corpus(root, min_len):
    corpus = set()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for name in filenames:
            if not name.endswith((".cls", ".trigger", ".apex")):
                continue
            try:
                with open(os.path.join(dirpath, name), encoding="utf-8", errors="ignore") as fh:
                    for line in fh:
                        text = normalize(line)
                        if len(text) >= min_len:
                            corpus.add(text)
            except OSError:
                continue
    return corpus


def embedded_tests(path):
    """Yield (test name, [normalized Apex lines]) for each Zig test block."""
    name, lines = None, []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.rstrip("\n")
            if raw.startswith('test "'):
                if name is not None:
                    yield name, lines
                name, lines = raw[6 : raw.rindex('"')], []
                continue
            stripped = raw.strip()
            if name is not None and stripped.startswith("\\\\"):
                lines.append(normalize(stripped[2:]))
    if name is not None:
        yield name, lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".local-fixtures/apex/repos")
    parser.add_argument("--min-len", type=int, default=30)
    parser.add_argument("--max-lines", type=int, default=2)
    args = parser.parse_args()

    if not os.path.isdir(args.root):
        print(f"{args.root} not found; nothing to compare against")
        return 0

    corpus = load_corpus(args.root, args.min_len)
    tracked = subprocess.run(
        ["git", "ls-files", "src"], capture_output=True, text=True, check=True
    ).stdout.split("\n")

    offenders = []
    checked = 0
    for path in tracked:
        if not path.endswith(".zig"):
            continue
        for name, lines in embedded_tests(path):
            checked += 1
            hits = [l for l in lines if len(l) >= args.min_len and l in corpus]
            if len(hits) > args.max_lines:
                offenders.append((path, name, hits))

    for path, name, hits in offenders:
        print(f"{path}: test \"{name}\" shares {len(hits)} lines with fixture sources")
        for hit in hits[:5]:
            print(f"    {hit}")
    print(f"checked {checked} tests, {len(offenders)} over the limit of {args.max_lines} lines")
    return 1 if offenders else 0


if __name__ == "__main__":
    sys.exit(main())
