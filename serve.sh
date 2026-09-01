#!/usr/bin/env bash
# Serve the generated gallery. VS Code auto-forwards the port to Windows,
# so http://localhost:8080 works in your normal browser.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-8080}"

[[ -f "$ROOT/gallery/index.html" ]] || { echo "Run ./build.sh first." >&2; exit 1; }

echo "http://localhost:${PORT}"
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/gallery"
