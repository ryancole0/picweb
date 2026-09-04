#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="$ROOT/.secrets"

GOOGLE_CLIENT_ID="$(<"$SECRETS/google-client-id.txt")"
GOOGLE_CLIENT_SECRET="$(<"$SECRETS/google-client-secret.txt")"
FAMILY_ALLOWLIST="$(grep -v '^\s*#' "$SECRETS/family-allowlist.txt" | grep -v '^\s*$' | paste -sd, -)"

RG=rg-picweb
SWA=swa-picweb-gallery

az staticwebapp appsettings set -n "$SWA" -g "$RG" \
  --setting-names \
    GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID" \
    GOOGLE_CLIENT_SECRET="$GOOGLE_CLIENT_SECRET" \
    FAMILY_ALLOWLIST="$FAMILY_ALLOWLIST"
