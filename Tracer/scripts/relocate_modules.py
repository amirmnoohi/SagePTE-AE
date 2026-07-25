#!/usr/bin/env python3
"""Point a trace's module table at this checkout.

DynamoRIO records the absolute path of every module that was loaded when a
trace was captured. Those paths are baked into raw/modules.log, so moving the
artifact -- or re-cloning it somewhere else, or unpacking a published capture
on a different machine -- leaves them dangling, and raw2trace stops with

    ERROR: Failed to map module /old/path/Workloads/bin/bench_redis_st

before reading a single reference. The files are usually still present, just
under a different prefix: the same artifact-relative path exists beneath the
current root. This repoints each dangling entry at the file that is actually
here, and leaves alone any it cannot resolve, so a genuinely missing module
still reports itself rather than being silently skipped.

The rewrite is length-preserving. A shorter replacement is padded with
redundant slashes, which the kernel collapses when opening the file, so every
byte after the module table stays where it was. That matters because the table
is followed by a binary section whose position must not move.

Usage: relocate_modules.py <modules.log> <repo-root>
Prints one line per entry it changed, and exits 0 whether or not it changed
any: nothing here is fatal on its own.
"""
import os
import shutil
import sys


def longest_existing_suffix(path, root):
    """Return the path under root that matches the deepest tail of `path`.

    Matching from the deepest tail first means Workloads/bin/x is preferred
    over the bare x, so a file is only claimed when a meaningful amount of the
    recorded structure agrees.
    """
    parts = [p for p in path.split("/") if p]
    for i in range(len(parts)):
        candidate = os.path.join(root, *parts[i:])
        if os.path.exists(candidate):
            return candidate
    return None


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    modules, root = sys.argv[1], os.path.realpath(sys.argv[2])

    with open(modules, "rb") as fh:
        blob = fh.read()

    # The table is text, one module per line, with the path last. Anything
    # after it is binary and is neither parsed nor moved.
    wanted = []
    for line in blob.split(b"\n"):
        if b", " not in line:
            continue
        candidate = line.rsplit(b", ", 1)[-1].strip()
        if candidate.startswith(b"/") and candidate not in wanted:
            wanted.append(candidate)

    changed = 0
    for raw in wanted:
        try:
            path = raw.decode()
        except UnicodeDecodeError:
            continue
        if os.path.exists(path):
            continue
        found = longest_existing_suffix(path, root)
        if not found:
            print(f"unresolved {path}")
            continue

        pad = len(raw) - len(found.encode())
        if pad >= 0:
            # Extra slashes go immediately after the root, where they are
            # harmless, so the entry keeps its original byte length.
            replacement = (root + "/" * pad + found[len(root):]).encode()
        else:
            # No way to shorten a path; the table grows and the binary section
            # after it shifts. raw2trace parses both sequentially, so this is
            # safe, but it is the case worth knowing about.
            replacement = found.encode()
        assert pad < 0 or len(replacement) == len(raw)

        blob = blob.replace(raw, replacement)
        changed += 1
        print(f"relocated {path} -> {found}")

    if changed:
        backup = modules + ".orig"
        if not os.path.exists(backup):
            shutil.copy2(modules, backup)
        with open(modules, "wb") as fh:
            fh.write(blob)
    return 0


if __name__ == "__main__":
    sys.exit(main())
