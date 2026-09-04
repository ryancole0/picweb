#!/usr/bin/env bash
# Measure the deployable payload against the Static Web Apps per-environment caps.
#
#   ./size-check.sh              # measures ./gallery (+ config/api if present)
#   OUT=/some/other/dir ./size-check.sh
#   TARGET_PHOTOS=4200 ./size-check.sh   # project full-library size from a sample
#
# Sourced by build.sh, or run on its own — it never rebuilds anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$ROOT/gallery}"
PHOTOS="${PHOTOS_DIR:-$ROOT/photos}"

# --- what the platform actually meters ---------------------------------------
# SWA counts content bytes. `du` reports allocated disk blocks, rounding every
# file up to 4 KiB — across ~10k thumbnails at 15-25 KB each that overstates the
# total by tens of MB and would have you deleting photos you did not need to.
# Sum apparent file sizes instead.
#
# 500 "MB" is not qualified as MB or MiB in the docs. Decimal is the smaller of
# the two readings, so it is the one that cannot bite you.
SWA_MAX_BYTES=$((500 * 1000 * 1000))
SWA_MAX_FILES=15000
WARN_PCT=80

# --- like-for-like payload ----------------------------------------------------
# A deploy replaces the whole environment, so the payload is the gallery plus
# anything else that ships with it. Count what will actually be uploaded, not
# just the Thumbsup output.
PAYLOAD=("$OUT")
[[ -f "$ROOT/static/staticwebapp.config.json" ]] && PAYLOAD+=("$ROOT/static/staticwebapp.config.json")
[[ -d "$ROOT/api" ]] && PAYLOAD+=("$ROOT/api")

[[ -d "$OUT" ]] || { echo "No output at $OUT — run ./build.sh first." >&2; exit 1; }

# -L so a symlinked photo tree is measured as the file it resolves to, which is
# what gets uploaded. -printf '%s' is the byte size, not the block count.
read -r BYTES FILES < <(
  find -L "${PAYLOAD[@]}" -type f -printf '%s\n' \
    | awk '{s += $1; n++} END {printf "%d %d\n", s + 0, n + 0}'
)

PHOTO_COUNT=$(find "$PHOTOS" -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) 2>/dev/null | wc -l)

pct() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.1f", (b ? a * 100 / b : 0)}'; }
human() { # `--` so a negative headroom is not parsed as an option
  local n="$1"
  if (( n < 0 )); then printf -- '-%s' "$(numfmt --to=si --suffix=B --format='%.1f' -- "$(( -n ))")"
  else numfmt --to=si --suffix=B --format='%.1f' -- "$n"; fi
}

BYTES_PCT=$(pct "$BYTES" "$SWA_MAX_BYTES")
FILES_PCT=$(pct "$FILES" "$SWA_MAX_FILES")

echo
echo "=== deployable payload ======================================"
printf '  paths      %s\n' "${PAYLOAD[*]#$ROOT/}"
printf '  size       %-10s of %s   (%s%%)\n' \
  "$(human "$BYTES")" "$(human "$SWA_MAX_BYTES")" "$BYTES_PCT"
printf '  files      %-10s of %s        (%s%%)\n' \
  "$FILES" "$SWA_MAX_FILES" "$FILES_PCT"
printf '  headroom   %s\n' "$(human $((SWA_MAX_BYTES - BYTES)))"

if (( PHOTO_COUNT > 0 )); then
  PER_PHOTO=$(( BYTES / PHOTO_COUNT ))
  printf '  sources    %s photos -> %s each\n' "$PHOTO_COUNT" "$(human "$PER_PHOTO")"

  # Extrapolate a 40-photo demo to the real library. This is the number that
  # decides the §5.3 default-path-vs-blob-fallback question, and finding it out
  # at stage 4 against 5 GB is expensive.
  if [[ -n "${TARGET_PHOTOS:-}" ]]; then
    PROJECTED=$(( PER_PHOTO * TARGET_PHOTOS ))
    printf '  projected  %s at %s photos   (%s%% of cap)\n' \
      "$(human "$PROJECTED")" "$TARGET_PHOTOS" "$(pct "$PROJECTED" "$SWA_MAX_BYTES")"
    if (( PROJECTED > SWA_MAX_BYTES )); then
      printf '             -> full library will not fit. Lower --large-size or\n'
      printf '                --photo-quality, or take the Blob fallback.\n'
    fi
  fi
fi

echo "  ---"
echo "  largest files:"
find -L "$OUT" -type f -printf '%s\t%P\n' | sort -rn | head -n 5 \
  | while IFS=$'\t' read -r sz path; do printf '    %8s  %s\n' "$(human "$sz")" "$path"; done

echo "  by directory:"
for d in "$OUT"/*/; do
  [[ -d "$d" ]] || continue
  dsz=$(find -L "$d" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
  printf '    %8s  %s\n' "$(human "$dsz")" "$(basename "$d")/"
done | sort -rh -k1
echo "============================================================"

# --- verdict ------------------------------------------------------------------
STATUS=0
if (( BYTES > SWA_MAX_BYTES )); then
  echo "FAIL: payload exceeds the 500 MB per-environment cap. Deploy will be rejected." >&2
  STATUS=1
elif (( $(awk -v p="$BYTES_PCT" -v w="$WARN_PCT" 'BEGIN {print (p >= w)}') )); then
  echo "WARN: payload is at ${BYTES_PCT}% of the size cap." >&2
fi

if (( FILES > SWA_MAX_FILES )); then
  echo "FAIL: $FILES files exceeds the 15,000 file cap." >&2
  STATUS=1
elif (( $(awk -v p="$FILES_PCT" -v w="$WARN_PCT" 'BEGIN {print (p >= w)}') )); then
  echo "WARN: file count is at ${FILES_PCT}% of the cap." >&2
fi

exit "$STATUS"
