#!/usr/bin/env bash
set -euo pipefail

set -a # automatically export all variables
source .env
set +a

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="$ROOT/.secrets"

FAMILY_ALLOWLIST="$(grep -v '^\s*#' "$SECRETS/family-allowlist.txt" | grep -v '^\s*$' | paste -sd, -)"
VALHEIM_ALLOWLIST="$(grep -v '^\s*#' "$SECRETS/valheim-allowlist.txt" | grep -v '^\s*$' | paste -sd, -)"

RG=rg-picweb
SWA=swa-picweb-gallery

az staticwebapp appsettings set -n "$SWA" -g "$RG" \
  --setting-names \
    GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID" \
    GOOGLE_CLIENT_SECRET="$GOOGLE_CLIENT_SECRET" \
    FAMILY_ALLOWLIST="$FAMILY_ALLOWLIST" \
    VALHEIM_ALLOWLIST="$VALHEIM_ALLOWLIST" \
    AZURE_TENANT_ID="$AZURE_TENANT_ID" \
    AZURE_CLIENT_ID="$AZURE_CLIENT_ID" \
    AZURE_CLIENT_SECRET="$AZURE_CLIENT_SECRET" \
    AZURE_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID" \
    VALHEIM_STORAGE_ACCOUNT="$VALHEIM_STORAGE_ACCOUNT" \
    VALHEIM_UAMI_ID="$VALHEIM_UAMI_ID" \
    VALHEIM_UAMI_CLIENT_ID="$VALHEIM_UAMI_CLIENT_ID" \
    VALHEIM_SERVER_PASSWORD="$VALHEIM_SERVER_PASSWORD" \
    VALHEIM_SSH_PUBKEY="$VALHEIM_SSH_PUBKEY"


