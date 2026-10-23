#!/usr/bin/env python3
"""Keep only the file sections of a unified git diff whose path matches a glob.

Usage: filter-diff.py IN OUT GLOB [GLOB...]

`gh pr diff` can exclude files but has no include filter, so the code-review
skill uses this to honor a scope restriction such as "only Rust files"
(`'*.rs'`). A file section starts at a line beginning with `diff --git `. Its
path is taken from the `b/` side (the `a/` side for a deleted file). A section
is kept when fnmatch matches its full path or its basename against any glob.

Prints `kept K of N files` and exits 0. Exits 2 on a usage error or when IN has
no `diff --git` header. Bytes are preserved (ESC sequences included).
"""
import fnmatch
import os
import re
import sys

HEADER = "diff --git "
# `diff --git a/<path> b/<path>`; paths with spaces still split on " b/".
HEADER_RE = re.compile(r"^diff --git (?:\"?a/(?P<a>.*?)\"?) (?:\"?b/(?P<b>.*?)\"?)$")


def section_path(header, body):
    """Return the repository-relative path a file section changes."""
    for line in body:
        if line.startswith("+++ "):
            target = line[4:].rstrip("\n")
            if target.startswith("b/"):
                return target[2:]
            break  # "+++ /dev/null": deleted file, use the a/ side below
    for line in body:
        if line.startswith("--- "):
            source = line[4:].rstrip("\n")
            if source.startswith("a/"):
                return source[2:]
            break
    m = HEADER_RE.match(header.rstrip("\n"))
    if m:
        return m.group("b") or m.group("a")
    return header[len(HEADER):].rstrip("\n")


def main(argv):
    if len(argv) < 4:
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 2
    src, dst, globs = argv[1], argv[2], argv[3:]
    with open(src, "rb") as fh:
        text = fh.read().decode("utf-8", "surrogateescape")
    lines = text.splitlines(keepends=True)

    preamble, sections, current = [], [], None
    for line in lines:
        if line.startswith(HEADER):
            current = [line]
            sections.append(current)
        elif current is None:
            preamble.append(line)
        else:
            current.append(line)
    if not sections:
        sys.stderr.write("filter-diff: no 'diff --git' header in %s\n" % src)
        return 2

    kept = []
    for section in sections:
        path = section_path(section[0], section[1:])
        base = os.path.basename(path)
        if any(fnmatch.fnmatch(path, g) or fnmatch.fnmatch(base, g) for g in globs):
            kept.append(section)

    out = "".join(preamble) + "".join("".join(s) for s in kept)
    with open(dst, "wb") as fh:
        fh.write(out.encode("utf-8", "surrogateescape"))
    print("kept %d of %d files" % (len(kept), len(sections)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
