#!/usr/bin/env python3
# scripts/dot_replit.py
"""tomlkit-backed manager for .replit [userenv.shared] toolchain keys.

Invoked by scripts/setup.sh. All edits are STRUCTURAL via tomlkit — no
awk/sed/grep line surgery, no marker comments: keys are added, updated in
place, or deleted by name inside the [userenv.shared] table. Everything
else in the file (operator keys, workflows, ports, formatting) round-trips
byte-identically, and the result is re-validated with stdlib tomllib
before the file is replaced atomically.

Modes (combinable):
  --set KEY=VALUE       add/update a [userenv.shared] key (toolchain install)
  --delete-key KEY      remove a [userenv.shared] key (shadowed vars, --clean)

Exit status: 0 on success (file replaced), 1 on any failure (file left
untouched — the caller restores its backup and dies).
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import sys
import tempfile
import tomllib

import tomlkit


def get_shared(doc, create: bool):
    """Return the [userenv.shared] table, optionally creating it."""
    userenv = doc.get("userenv")
    if userenv is None:
        if not create:
            return None
        userenv = tomlkit.table()
        doc.append("userenv", userenv)
    shared = userenv.get("shared")
    if shared is None:
        if not create:
            return None
        shared = tomlkit.table()
        userenv.append("shared", shared)
    return shared


def apply_keys(table, delete_keys, pairs):
    """Apply deletes then (set) updates to a tomlkit table, in place."""
    for key in delete_keys:
        if key in table:
            del table[key]
    for key, value in pairs:
        # __setitem__ updates in place (position preserved) or appends.
        table[key] = value


def update_userenv(
    path: str,
    delete_keys: set[str],
    pairs: list[tuple[str, str]],
) -> None:
    with open(path, encoding="utf-8") as fh:
        original = fh.read()

    try:
        doc = tomlkit.parse(original)
    except Exception as exc:
        raise RuntimeError(f".replit does not parse as TOML: {exc}") from exc

    shared = get_shared(doc, create=bool(pairs or delete_keys))
    if shared is not None:
        apply_keys(shared, delete_keys, pairs)

    # A clean can empty [userenv.shared] — drop it again rather than leaving
    # a bare `[userenv.shared]` header behind.
    if not pairs and shared is not None and len(shared) == 0:
        userenv = doc["userenv"]
        del userenv["shared"]
        if len(userenv) == 0:
            del doc["userenv"]

    rendered = tomlkit.dumps(doc)
    # The rewritten file is user config: verify it still parses as TOML
    # (stdlib tomllib, independent of tomlkit) before touching the file.
    tomllib.loads(rendered)

    # Same-dir temp + os.replace: atomic, and never leaves a half-written
    # .replit behind on crash. mkstemp always creates 0600, so carry the
    # ORIGINAL file's mode across the replace — otherwise every write
    # silently narrows .replit to owner-only.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(rendered)
        os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
        Path(tmp).replace(path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def main() -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--file", required=True, help="path to the .replit file")
    ap.add_argument(
        "--delete-key",
        action="append",
        default=[],
        help="userenv key to remove (repeatable)",
    )
    ap.add_argument(
        "--set",
        dest="pairs",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="userenv entry to add/update (repeatable)",
    )

    args = ap.parse_args()

    def parse_pairs(raw_items, flag):
        out: list[tuple[str, str]] = []
        for raw in raw_items:
            key, sep, value = raw.partition("=")
            if not sep or not key:
                ap.error(f"{flag} expects KEY=VALUE, got {raw!r}")
            out.append((key, value))
        return out

    pairs = parse_pairs(args.pairs, "--set")

    try:
        update_userenv(
            args.file,
            set(args.delete_key),
            pairs,
        )
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())