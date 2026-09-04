"""
GetRoles — SWA custom roles function for the family gallery.

Invoked by the platform on every sign-in. Request body carries
identityProvider, userId, userDetails, claims, accessToken. Must respond
{"roles": [...]}  and must never raise, or sign-in breaks for everyone.

Allowlist source: FAMILY_ALLOWLIST app setting, comma-separated addresses.
Loaded and normalised once at module load (cold start), not per request.

Set DEBUG_LOG_CLAIMS=true as a temporary app setting to log the raw claims
list on the next sign-in, to confirm the actual claim type names your OIDC
provider sends. Turn it back off (or delete the setting) once confirmed --
claims can contain PII and don't belong in logs long-term.
"""

import json
import logging
import os

import azure.functions as func

ROLE_FAMILY = "family"

# Known claim type spellings for email / email_verified across providers.
# Google's OIDC discovery document uses the plain names below; this list
# exists so the same function tolerates a different provider without a code
# change, not because we expect more than the first entry to ever match.
EMAIL_VERIFIED_CLAIM_TYPES = (
    "email_verified",
    "http://schemas.microsoft.com/identity/claims/email_verified",
)
EMAIL_CLAIM_TYPES = (
    "email",
    "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress",
)


def _normalize_email(address: str) -> str:
    """Lowercase, strip +tag, and strip dots for gmail/googlemail addresses.

    jane.doe+photos@gmail.com and janedoe@gmail.com are the same mailbox.
    Gmail ignores dots in the local part and treats +anything as a tag;
    other providers don't share this behaviour, so only gmail.com and
    googlemail.com get the dot-stripping step.
    """
    address = (address or "").strip().lower()
    if "@" not in address:
        return address

    local, _, domain = address.rpartition("@")
    local = local.split("+", 1)[0]

    if domain in ("gmail.com", "googlemail.com"):
        local = local.replace(".", "")
        domain = "gmail.com"

    return f"{local}@{domain}"


def _load_allowlist() -> frozenset:
    raw = os.environ.get("FAMILY_ALLOWLIST", "")
    addresses = (a.strip() for a in raw.split(","))
    return frozenset(_normalize_email(a) for a in addresses if a)


def _claims_map(claims) -> dict:
    result = {}
    for c in claims or []:
        typ = c.get("typ")
        val = c.get("val")
        if typ is not None:
            result[typ] = val
    return result


def _first_present(mapping: dict, keys) -> str | None:
    for key in keys:
        if key in mapping:
            return mapping[key]
    return None


def _is_truthy_claim(value) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() == "true"


# Loaded once per cold start, not per request.
_ALLOWLIST = _load_allowlist()


def main(req: func.HttpRequest) -> func.HttpResponse:
    empty = func.HttpResponse(
        json.dumps({"roles": []}),
        mimetype="application/json",
        status_code=200,
    )

    try:
        body = req.get_json()
    except ValueError:
        logging.warning("GetRoles: request body was not valid JSON")
        return empty

    if os.environ.get("DEBUG_LOG_CLAIMS", "").strip().lower() == "true":
        logging.warning("GetRoles debug claims: %s", body.get("claims"))

    claims = _claims_map(body.get("claims"))

    email_verified_raw = _first_present(claims, EMAIL_VERIFIED_CLAIM_TYPES)
    if not _is_truthy_claim(email_verified_raw):
        logging.info("GetRoles: rejecting sign-in, email_verified not true")
        return empty

    # userDetails is the platform-resolved nameClaimType value (config.json
    # sets nameClaimType to "email"), so it should already be the address.
    # Fall back to the raw claim if userDetails is ever absent.
    email = body.get("userDetails") or _first_present(claims, EMAIL_CLAIM_TYPES)
    if not email:
        logging.warning("GetRoles: no email found on claims or userDetails")
        return empty

    if _normalize_email(email) not in _ALLOWLIST:
        logging.info("GetRoles: %s not on allowlist", _normalize_email(email))
        return empty

    return func.HttpResponse(
        json.dumps({"roles": [ROLE_FAMILY]}),
        mimetype="application/json",
        status_code=200,
    )
