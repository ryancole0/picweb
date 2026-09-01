#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"   # tomllib
# dependencies = []
# ///
"""
Prune photo keywords down to an allowlist.

Reads tags-allowed.toml (or tags.json), scans a photo tree with exiftool, and removes
every keyword not on the list from all five fields digiKam writes.

    ./prune-tags.py photos/                  # report what would change
    ./prune-tags.py photos/ --apply          # rewrite the files

Close digiKam first. Afterwards, in digiKam: select all, then
Item -> Reread Metadata From File, or its database will push the old tags back.

Requires exiftool:  sudo apt install libimage-exiftool-perl
Python 3.11+ is fetched automatically by uv. Without uv, run it under any
3.11+ interpreter directly — the metadata block above is only comments.
"""

import argparse
import json
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    tomllib = None

# Flat fields hold leaf names ("Bergen"). Hierarchical fields hold full
# paths ("Steder/Bergen"). digiKam writes all five; prune all five.
FLAT_FIELDS = ["IPTC:Keywords", "XMP-dc:Subject"]
HIER_FIELDS = [
    "XMP-lr:HierarchicalSubject",
    "XMP-digiKam:TagsList",
    "XMP-microsoft:LastKeywordXMP",
]
FIELDS = FLAT_FIELDS + HIER_FIELDS

EXTS = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "xmp"]


def load_allowlist(path):
    """Return (allowed_paths, allowed_leaves) sets."""
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".toml":
        if tomllib is None:
            sys.exit("Python 3.11+ needed for .toml, or use a .json allowlist.")
        data = tomllib.loads(text)
    else:
        data = json.loads(text)

    raw = data["tags"] if isinstance(data, dict) else data
    paths, leaves = set(), set()
    for entry in raw:
        entry = entry.strip().strip("/")
        if not entry:
            continue
        parts = entry.split("/")
        leaves.update(p.strip() for p in parts)
        # keep the tag itself and every ancestor of it
        for i in range(1, len(parts) + 1):
            paths.add("/".join(p.strip() for p in parts[:i]))
    return paths, leaves


def read_metadata(root):
    cmd = ["exiftool", "-json", "-charset", "filename=utf8", "-G1", "-a", "-r"]
    for ext in EXTS:
        cmd += ["-ext", ext]
    cmd += [f"-{f}" for f in FIELDS]
    cmd += [str(root)]

    proc = subprocess.run(cmd, capture_output=True, text=True)
    if not proc.stdout.strip():
        sys.exit(proc.stderr.strip() or f"No readable files under {root}")
    return json.loads(proc.stdout)


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v) for v in value]
    return [str(value)]


def plan(records, allowed_paths, allowed_leaves):
    """Yield (source_file, {field: kept_values}) for files that need changes."""
    dropped = Counter()
    for record in records:
        source = record["SourceFile"]
        changes = {}
        for field in FIELDS:
            current = as_list(record.get(field))
            if not current:
                continue
            allowed = allowed_paths if field in HIER_FIELDS else allowed_leaves
            kept = [v for v in current if v in allowed]
            if kept != current:
                changes[field] = kept
                dropped.update(v for v in current if v not in allowed)
        if changes:
            yield source, changes, dropped


def build_args(planned):
    """Build an exiftool -@ argfile: one -execute block per file."""
    lines = []
    for source, changes in planned:
        lines += ["-charset", "filename=utf8", "-overwrite_original", "-P"]
        for field, kept in changes.items():
            lines.append(f"-{field}=")          # clear the field
            for value in kept:                  # then re-add survivors
                lines.append(f"-{field}={value}")
        lines.append(source)
        lines.append("-execute")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("photos", nargs="?", default="photos", type=Path)
    ap.add_argument("-l", "--allowlist", default="tags-allowed.toml", type=Path)
    ap.add_argument("--apply", action="store_true",
                    help="write the changes (default is a dry run)")
    args = ap.parse_args()

    if not args.photos.is_dir():
        sys.exit(f"Not a directory: {args.photos}")

    allowed_paths, allowed_leaves = load_allowlist(args.allowlist)
    records = read_metadata(args.photos)

    planned, dropped = [], Counter()
    for source, changes, counter in plan(records, allowed_paths, allowed_leaves):
        planned.append((source, changes))
        dropped = counter

    print(f"scanned:  {len(records)} files")
    print(f"affected: {len(planned)} files")

    if not planned:
        print("Nothing to do.")
        return

    print("\ntags to be removed (count of field occurrences):")
    for tag, count in dropped.most_common():
        print(f"  {count:5d}  {tag}")

    if not args.apply:
        print("\nDry run. Review the list above, add anything you meant to keep to")
        print(f"{args.allowlist}, then re-run with --apply.")
        return

    argfile = tempfile.NamedTemporaryFile("w", suffix=".args",
                                          encoding="utf-8", delete=False)
    with argfile as fh:
        fh.write(build_args(planned))

    proc = subprocess.run(["exiftool", "-@", argfile.name])
    Path(argfile.name).unlink(missing_ok=True)
    if proc.returncode != 0:
        sys.exit(proc.returncode)

    print("\nDone. Now: reopen digiKam, select all, "
          "Item -> Reread Metadata From File.")
    print("Then delete .cache/thumbsup.db so the next build re-reads keywords.")


if __name__ == "__main__":
    main()