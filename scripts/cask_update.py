#!/usr/bin/env python3
"""Bump version + sha256 in Casks/flow-bar.rb.

Replaces the inline `sed -i '' -E "s/sha256 .*/…/"` this used to be. That
pattern was unanchored, so it would happily rewrite any line starting with
`sha256` — including one inside a comment — and `|| echo "no cask change"`
meant a botched rewrite still produced a green release.

Usage: cask_update.py <version> <sha256>
"""

import pathlib
import re
import sys

CASK = pathlib.Path(__file__).resolve().parent.parent / "Casks" / "flow-bar.rb"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    version, sha = sys.argv[1], sys.argv[2]

    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        print(f"error: version {version!r} is not X.Y.Z", file=sys.stderr)
        return 1
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        print(f"error: sha256 {sha!r} is not 64 hex chars", file=sys.stderr)
        return 1

    src = CASK.read_text()

    # Anchored to the stanza at the start of a line, so comments are untouched.
    src, n_ver = re.subn(r'^(\s*version\s+)"[^"]*"', rf'\g<1>"{version}"',
                         src, count=1, flags=re.MULTILINE)
    src, n_sha = re.subn(r'^(\s*sha256\s+)"[^"]*"', rf'\g<1>"{sha}"',
                         src, count=1, flags=re.MULTILINE)

    # Fail loudly rather than silently shipping a stale cask.
    if n_ver != 1:
        print("error: could not find a `version \"…\"` stanza", file=sys.stderr)
        return 1
    if n_sha != 1:
        print("error: could not find a `sha256 \"…\"` stanza", file=sys.stderr)
        return 1

    CASK.write_text(src)
    print(f"cask updated: version {version}, sha256 {sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
