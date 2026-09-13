"""
Shared helpers for the Valheim server control functions.

Talks to ARM over plain REST rather than the azure-mgmt-* SDKs. Those packages
are large, and every dependency in this app is imported at cold start -- which
is also GetRoles' cold start, on the critical path of every sign-in to the
gallery. azure-identity and requests are imported lazily inside _session() for
the same reason: signing in should not pay for code only the Valheim page uses.

App settings required (see README):
  AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
  VALHEIM_STORAGE_ACCOUNT, VALHEIM_UAMI_ID, VALHEIM_UAMI_CLIENT_ID
  VALHEIM_SERVER_PASSWORD, VALHEIM_SSH_PUBKEY
  optional: VALHEIM_SERVER_NAME, VALHEIM_WORLD_NAME, VALHEIM_VM_SIZE, VALHEIM_USE_SPOT
"""

import base64
import json
import logging
import os
import time
from pathlib import Path

import azure.functions as func

ROLE_VALHEIM = "valheim"
RG = "rg-valheim-server"
VM_NAME = "valheim-vm"
PIP_NAME = "valheim-pip"

REGIONS = {
    "eastus": "East US (Virginia)",
    "southcentralus": "South Central US (Dallas)",
    "swedencentral": "Sweden Central (Stockholm)",
}

ARM = "https://management.azure.com"
API_DEPLOY = "2021-04-01"
API_COMPUTE = "2024-07-01"
API_NETWORK = "2024-01-01"

_TEMPLATES = Path(__file__).resolve().parent.parent / "templates"

_credential = None
_session = None


def _client():
    """Lazily build a credential + HTTP session. Cached for the worker's life."""
    global _credential, _session
    if _session is None:
        import requests
        from azure.identity import ClientSecretCredential

        _credential = ClientSecretCredential(
            tenant_id=os.environ["AZURE_TENANT_ID"],
            client_id=os.environ["AZURE_CLIENT_ID"],
            client_secret=os.environ["AZURE_CLIENT_SECRET"],
        )
        _session = requests.Session()
    return _credential, _session


def _call(method: str, path: str, api_version: str, body=None, params=None):
    """One ARM call. Returns (status_code, parsed_json_or_None)."""
    credential, session = _client()
    # ClientSecretCredential caches and refreshes the token internally.
    token = credential.get_token("https://management.azure.com/.default").token
    sub = os.environ["AZURE_SUBSCRIPTION_ID"]
    query = {"api-version": api_version}
    query.update(params or {})
    response = session.request(
        method,
        f"{ARM}/subscriptions/{sub}{path}",
        params=query,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json=body,
        timeout=30,
    )
    payload = None
    if response.content:
        try:
            payload = response.json()
        except ValueError:
            payload = None
    return response.status_code, payload


def _template(name: str) -> dict:
    with open(_TEMPLATES / name, encoding="utf-8") as handle:
        return json.load(handle)


# --------------------------------------------------------------------------
# request helpers
# --------------------------------------------------------------------------

def json_response(payload: dict, status_code: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(payload),
        mimetype="application/json",
        status_code=status_code,
    )


def principal(req: func.HttpRequest):
    """Decode the SWA client principal header, or None.

    Route rules in staticwebapp.config.json already gate /api/valheim/* on the
    valheim role. This is the second check, so a bad merge of the config file
    fails closed rather than opening the server to everyone in the family.
    """
    header = req.headers.get("x-ms-client-principal")
    if not header:
        return None
    try:
        decoded = json.loads(base64.b64decode(header).decode("utf-8"))
    except Exception:
        logging.warning("valheim: could not decode client principal header")
        return None
    if ROLE_VALHEIM not in (decoded.get("userRoles") or []):
        return None
    return decoded


def forbidden() -> func.HttpResponse:
    return json_response({"error": "You do not have the valheim role."}, 403)


# --------------------------------------------------------------------------
# state
# --------------------------------------------------------------------------

def _latest_deployment():
    status, body = _call(
        "GET", f"/resourcegroups/{RG}/providers/Microsoft.Resources/deployments",
        API_DEPLOY, params={"$top": "5"},
    )
    if status != 200 or not body:
        return None
    items = body.get("value") or []
    # Ordering is not contractually newest-first, so sort explicitly.
    items.sort(key=lambda d: (d.get("properties") or {}).get("timestamp") or "", reverse=True)
    return items[0] if items else None


def current_status() -> dict:
    status, vm = _call(
        "GET", f"/resourceGroups/{RG}/providers/Microsoft.Compute/virtualMachines/{VM_NAME}",
        API_COMPUTE, params={"$expand": "instanceView"},
    )
    if status == 404:
        vm = None
    elif status != 200:
        raise RuntimeError(f"ARM returned {status} reading the VM")

    latest = _latest_deployment()
    properties = (latest or {}).get("properties") or {}
    in_flight = properties.get("provisioningState") in ("Running", "Accepted")
    tearing_down = (latest or {}).get("name", "").startswith(("teardown", "destroy"))

    if vm is None:
        if in_flight and not tearing_down:
            region = ((properties.get("parameters") or {}).get("location") or {}).get("value")
            return {"state": "starting", "region": region, "deployment": latest.get("name")}
        return {"state": "off"}

    ip = fqdn = None
    pip_status, pip = _call(
        "GET", f"/resourceGroups/{RG}/providers/Microsoft.Network/publicIPAddresses/{PIP_NAME}",
        API_NETWORK,
    )
    if pip_status == 200:
        pip_props = pip.get("properties") or {}
        ip = pip_props.get("ipAddress")
        fqdn = (pip_props.get("dnsSettings") or {}).get("fqdn")

    players = None
    server_up = False
    if ip:
        try:
            _, session = _client()
            probe = session.get(f"http://{ip}/status", timeout=3)
            if probe.ok:
                players = probe.json().get("player_count", 0)
                server_up = True
        except Exception:
            # Normal for the first few minutes: Steam is still downloading.
            pass

    vm_props = vm.get("properties") or {}
    statuses = ((vm_props.get("instanceView") or {}).get("statuses")) or []
    power = next(
        (s["code"].split("/", 1)[1] for s in statuses
         if s.get("code", "").startswith("PowerState/")),
        None,
    )

    return {
        "state": "stopping" if (in_flight and tearing_down) else ("running" if server_up else "booting"),
        "region": vm.get("location"),
        "regionLabel": REGIONS.get(vm.get("location")),
        "vmSize": (vm_props.get("hardwareProfile") or {}).get("vmSize"),
        "power": power,
        "ip": ip,
        "fqdn": fqdn,
        "joinAddress": f"{ip}:2456" if ip else None,
        "players": players,
        "deployedAt": (vm.get("tags") or {}).get("deployedAt"),
    }


# --------------------------------------------------------------------------
# actions
# --------------------------------------------------------------------------

def start(region: str) -> tuple:
    name = f"start-{region}-{int(time.time())}"
    parameters = {
        "location": {"value": region},
        "vmSize": {"value": os.environ.get("VALHEIM_VM_SIZE", "Standard_D2as_v7")},
        "useSpot": {"value": os.environ.get("VALHEIM_USE_SPOT", "false") == "true"},
        "storageAccountName": {"value": os.environ["VALHEIM_STORAGE_ACCOUNT"]},
        "vmIdentityResourceId": {"value": os.environ["VALHEIM_UAMI_ID"]},
        "vmIdentityClientId": {"value": os.environ["VALHEIM_UAMI_CLIENT_ID"]},
        "serverName": {"value": os.environ.get("VALHEIM_SERVER_NAME", "Family Valheim")},
        "worldName": {"value": os.environ.get("VALHEIM_WORLD_NAME", "Midgard")},
        "serverPassword": {"value": os.environ["VALHEIM_SERVER_PASSWORD"]},
        "adminSshPublicKey": {"value": os.environ["VALHEIM_SSH_PUBKEY"]},
    }
    status, body = _call(
        "PUT",
        f"/resourcegroups/{RG}/providers/Microsoft.Resources/deployments/{name}",
        API_DEPLOY,
        body={"properties": {
            "mode": "Incremental",
            "template": _template("server.json"),
            "parameters": parameters,
        }},
    )
    return status, body, name


def stop() -> tuple:
    """Ask the VM to save, sync to blob, and delete itself."""
    return _call(
        "POST",
        f"/resourceGroups/{RG}/providers/Microsoft.Compute/virtualMachines/{VM_NAME}/runCommand",
        API_COMPUTE,
        body={
            "commandId": "RunShellScript",
            "script": ["systemctl start valheim-teardown.service"],
        },
    )


def destroy() -> tuple:
    """Force: complete-mode empty deployment wipes everything in the RG."""
    name = f"destroy-{int(time.time())}"
    status, body = _call(
        "PUT",
        f"/resourcegroups/{RG}/providers/Microsoft.Resources/deployments/{name}",
        API_DEPLOY,
        body={"properties": {"mode": "Complete", "template": _template("empty.json")}},
    )
    return status, body, name
