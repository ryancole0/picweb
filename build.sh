#!/usr/bin/env bash
# Build the gallery with Thumbsup in Docker. Extra args are passed through,
# e.g.  ./build.sh --log info
set -euo pipefail

FULL_REBUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full-rebuild) FULL_REBUILD=true; shift ;;
    *) break ;;                      # leave the rest in "$@"
  esac
done

THUMBSUP_TAG="2.18.0"
IMAGE="ghcr.io/thumbsup/thumbsup:${THUMBSUP_TAG}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHOTOS="${PHOTOS_DIR:-$ROOT/photos}"
OUT="$ROOT/gallery"
CACHE="$ROOT/.cache"

if [[ ! -d "$PHOTOS" ]]; then
  echo "No photo folder at $PHOTOS — create it or set PHOTOS_DIR." >&2
  exit 1
fi

# delete all *.identifier files in photos/ and its immediate subfolders
find photos -maxdepth 2 -type f -iname '*.identifier' -print -delete

# strip GPS info
exiftool -gps:all= photos/

case "$PHOTOS" in
  /mnt/[a-z]/*)
    echo "WARNING: $PHOTOS is on the Windows filesystem. Expect 5-20x slower" >&2
    echo "         builds and possible ownership oddities. Move it under \$HOME." >&2
    ;;
esac

if [[ "$FULL_REBUILD" == true ]]; then
  echo "full rebuild - deleting old files"
  rm -rf "$OUT" "$CACHE"
  mkdir -p "$OUT" "$CACHE"
fi
echo $FULL_REBUILD


docker run --rm -t \
  -v "$PHOTOS:/input:ro" \
  -v "$OUT:/output" \
  -v "$CACHE:/cache" \
  -v "$ROOT/thumbsup.json:/config/thumbsup.json:ro" \
  -v "$ROOT/custom.less:/config/custom.less:ro" \
  -v /etc/localtime:/etc/localtime:ro \
  -u "$(id -u):$(id -g)" \
  "$IMAGE" \
  thumbsup --config /config/thumbsup.json "$@"

echo
echo "=== deployable output ==============================="
du -sh "$OUT"
printf 'files:  %s\n' "$(find "$OUT" -type f | wc -l)"
printf 'photos: %s\n' "$(find "$PHOTOS" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) | wc -l)"
echo "SWA Standard caps: 500 MB per environment, 15,000 files."
echo "====================================================="

./size-check.sh

