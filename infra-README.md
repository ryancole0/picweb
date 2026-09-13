# On-demand Valheim server, driven from your family gallery SWA

## The shape of it (outdated, this has been merged with picweb and some folder structure has changed)

```
 Family (Google OAuth, role "valheim")
        │
        ▼
 Static Web App (existing, Standard)
   /valheim.html  ── hidden page: pick region, Start / Save-and-stop / Force-delete
   /api/valheim/*       ── managed function (Node 20) using a service principal
        │  ARM: deployment (start) · Run Command (stop) · complete-mode empty deployment (destroy)
        ▼
 rg-valheim-server  (disposable — wiped on every stop)
   valheim-vm  B2as_v2, Ubuntu 24.04, region = eastus | southcentralus | swedencentral
   ├─ docker: ghcr.io/lloesche/valheim-server  (UDP 2456-2457, status JSON on :80)
   ├─ restore.sh   boot: pull world from blob
   ├─ sync.sh      every 5 min + on stop: push world + backup zips to blob
   ├─ idle-check   every min: 0 players for 30 min (after 20 min grace) → teardown
   └─ teardown.sh  stop container (saves) → sync → delete everything in the RG (own identity)
        │
        ▼
 rg-valheim-core  (permanent, ~$0.05/mo)
   stvalheim…  blob container "valheim": worlds_local/  backups/   (versioning + 30-day soft delete)
   id-valheim-vm  user-assigned identity: Blob Data Contributor on storage, Contributor on rg-valheim-server
```

Why it's built this way:

- **World data never lives on the VM's disk alone.** The VM is cattle. The blob container is the source of truth; the VM pulls at boot and pushes every 5 minutes, on graceful stop, and after each zipped backup. Blob versioning + soft delete let you roll back a bad save from the portal. Cross-region reads of a few MB take seconds, so one storage account serves all three regions.
- **Exactly one server at a time.** `start` refuses if anything exists in `rg-valheim-server`. Two servers syncing one world would clobber each other.
- **Destroy = empty complete-mode deployment.** Everything in the RG is deleted (VM, disk, NIC, IP, VNet, NSG). Nothing bills while off. The VM does this to itself, so a `stop` is: save → upload → self-delete, with the SWA API only sending the trigger. `destroy` is the no-questions fallback from the API side.
- **No role assignments at deploy time.** The VM's identity is pre-created and pre-authorized in `core.bicep`, so the service principal only needs Contributor on the disposable RG (+ Managed Identity Operator on the identity, Reader on core). It can't touch your gallery or anything else.
- **Region is a Start-time parameter.** No Azure region is in New York; East US (Virginia) is the practical midpoint for Oslo ↔ Dallas. Rough RTTs: Oslo→East US ~95 ms, Dallas→East US ~35 ms, Oslo→Dallas ~140 ms. Valheim is very tolerant up to ~150 ms; above that you feel it in combat.

## Files (paths may be outdated after merge with picweb)

| Path | What |
|---|---|
| `infra/core.bicep` (+ `core-resources.bicep`, `rg-roles.bicep`) | One-time, subscription scope: RGs, storage, identity, RBAC |
| `infra/server.bicep` + `infra/cloud-init.yaml` | The disposable VM. Compiled to JSON and embedded in the API |
| `infra/empty.json` | Complete-mode "delete everything" template |
| `api/` | Python v1 functions: `GetRoles` (roles + allowlists) and four Valheim controls |
| `app/valheim/index.html` | The hidden page |
| `app/staticwebapp.config.json` | Route/role entries to merge into yours |

## Setup
0. **Configure Subscription**
  Add `Microsoft.Network` and `Microsoft.Compute` as a registered providers for the subscription


1. **Service principal for the API**
   ```bash
   az ad sp create-for-rbac -n sp-valheim-swa --skip-assignment
   # note appId, password==AZURE_CLIENT_SECRET, tenant; then:
   
   az ad sp show --id <appId> --query id -o tsv     
   # objectId for core.bicep
   ```
2. **Core infra** (once)
   ```bash
   az deployment sub create -l eastus -f infra/core.bicep -p swaPrincipalObjectId=<objectId>
   az deployment sub show -n core --query properties.outputs   # storageAccountName, vmIdentityResourceId, vmIdentityClientId
   ```
3. Add policy limiting to only 1 VM
   ```
   az deployment sub create -l eastus -f infra/policy.bicep
   # verify the built-in GUIDs resolved:
   az policy assignment list -g rg-valheim-server -o table
   # test the deny actually bites:
   az vm create -g rg-valheim-server -n not-valheim --image Ubuntu2404 --size Standard_D64s_v5
   # fails by RequestDisallowedByPolicy
   ```

4. **Compile the server template into the API**
   ```bash
   az bicep build -f infra/server.bicep --outfile api/templates/server.json
   ```
   Re-run whenever you change `server.bicep` or `cloud-init.yaml`. (Add it to your CI step before the SWA deploy.)
5. **SWA app settings** (Portal → your SWA → Environment variables, or `az staticwebapp appsettings set`)
   `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_SUBSCRIPTION_ID`,
   `VALHEIM_STORAGE_ACCOUNT`, `VALHEIM_UAMI_ID`, `VALHEIM_UAMI_CLIENT_ID`,
   `VALHEIM_SERVER_PASSWORD` (≥5 chars), `VALHEIM_SSH_PUBKEY`,
   optional: `VALHEIM_SERVER_NAME`, `VALHEIM_WORLD_NAME`, `VALHEIM_VM_SIZE`, `VALHEIM_USE_SPOT`.
6. **Wire into the gallery repo**
   - Copy the four `Valheim*` folders and `shared_code/` and `templates/` into your existing `api/`, and merge `requirements.txt` (adds `azure-identity` and `requests`). Replace `GetRoles/__init__.py` with the version here. Your `host.json` and `GetRoles/function.json` are unchanged.
   - Copy `app/valheim.html` into the Thumbsup **output** (or better, a post-build copy step, since Thumbsup regenerates the folder). Merge the routes into your `staticwebapp.config.json`.
7. **Allow list**: because `rolesSource` is configured, portal invitations are ignored. Add a `VALHEIM_ALLOWLIST` app setting (comma-separated addresses) alongside your existing `FAMILY_ALLOWLIST`. An address must be on both: the family list is the prerequisite, the valheim list grants the extra role. Unset means nobody gets it, which is the safe default for a list that can spend money. Changes take effect at next sign-in (the lists load at cold start), so sign out and back in to test.
8. **First run**: open `/valheim`, pick a region, Start. First boot downloads the Valheim server from Steam (~1 GB) — 3–5 minutes. Later boots are the same (fresh VM each time) unless you bake an image; not worth it at this play frequency.

Existing world? Upload your `.db`/`.fwl` to `valheim/worlds_local/` in the storage account before the first start and set `VALHEIM_WORLD_NAME` to match.

## Cost

| Item | While on | While off |
|---|---|---|
| Standard_B2as_v2 (2 vCPU / 8 GiB) East US | ~$0.075/h | 0 |
| Standard public IP | ~$0.005/h | 0 |
| 32 GB StandardSSD OS disk | ~$0.003/h | 0 |
| Storage account (LRS, a few hundred MB with versions) | — | ~$0.05/mo |
| Egress | first 100 GB/mo free; Valheim ≈ 0.5–1 GB/h with 4 players | |
| SWA Standard | already paying | |

Playing 5 nights × 3 h ≈ 60 h/mo ≈ **$5–6/mo**. Idle-shutdown is the real cost control: a forgotten VM is ~$60/mo.
Spot (`VALHEIM_USE_SPOT=true`) roughly halves the VM price; eviction deletes the VM (the last sync is ≤5 min old) but drops everyone mid-session. Try it only if your evenings can absorb that.

## When to size up

Valheim's server is mostly single-threaded; it scales with **explored world + active players**, not much else.

| Symptom | Likely cause | Fix |
|---|---|---|
| Everyone rubber-bands/lags at once, regardless of location; enemies teleport | CPU-bound | Run Command `docker stats --no-stream` — a steady 100%+ of one core means step up |
| Fine for the first hour, then degrades in the evening | B-series credits exhausted → throttled | Azure Monitor metric *CPU Credits Remaining* hits 0 → `VALHEIM_VM_SIZE=Standard_D2as_v7` (~$0.086/h, no credits, same RAM) |
| Server crashes/restarts after long sessions; `free -m` shows <500 MB | RAM (big explored worlds want 10 GB+) | `Standard_B4as_v2` or `Standard_D4as_v5` (16 GiB) |
| Only one household lags; the other is fine | Latency, not the server | Different region for that night |
| Long "loading world" on join, slow terrain | Disk/boot; not the VM size | Ignore unless persistent; StandardSSD is fine |
| Status page shows players but nobody can hear/see anyone | Packet loss to region | Change region; check with `ping`/`mtr` to the VM's IP |

Rule of thumb: 2 vCPU/8 GiB is comfortable for up to ~5 players on a mid-sized world. Go to 4 vCPU/16 GiB when the world is heavily explored or you pass 6 players.

## Operating notes

- Admin without SSH: `az vm run-command invoke -g rg-valheim-server -n valheim-vm --command-id RunShellScript --scripts "journalctl -t valheim -n 50"`. Container logs: `docker logs valheim --tail 100`.
- Roll back a world: Storage account → container `valheim` → `worlds_local/<world>.db` → Versions → restore, or grab a zip from `backups/`. Do it while the server is off.
- Mods: `lloesche/valheim-server` supports BepInEx/ValheimPlus via env vars in `docker-compose.yml`; add them in `cloud-init.yaml` and recompile.
- Steam updates happen automatically at each boot, because every boot is a fresh install.
- The lock on "one server at a time" is checked at Start via the API. If you ever see two VMs, force-delete and sort out the world from blob versions.
TODO:

## Least-privilege roles (no Contributor)

Two custom roles in `infra/roles.bicep`, both with `assignableScopes` limited to `rg-valheim-server`:

| Role | Principal | Can | Cannot |
|---|---|---|---|
| **Valheim Server Deployer** | SWA service principal | write/read/delete VM, disk, NIC, public IP, VNet, NSG; run deployments; `runCommand/action` | create any other resource type; assign roles; touch any other RG |
| **Valheim Server Destroyer** | VM user-assigned identity | read + delete those same six types; run deployments | create or modify anything |

Neither contains `Microsoft.Authorization/*`, so no principal can widen its own access. The Destroyer has no write action at all — a compromised VM identity can end your game session and nothing else.

Also narrowed: the VM identity's Storage Blob Data Contributor is scoped to the `valheim` **container**, not the account, and the API's Reader on `rg-valheim-core` is gone (it never called ARM there — it reads the storage account name from app settings).

### Migrating off Contributor

```bash
az deployment sub create -l eastus -f infra/core.bicep -p swaPrincipalObjectId=<objectId>

# remove the old assignments (they are not deleted automatically)
RG=$(az group show -n rg-valheim-server --query id -o tsv)
az role assignment list --scope $RG --role Contributor -o table
az role assignment delete --scope $RG --role Contributor --assignee <swaAppId>
az role assignment delete --scope $RG --role Contributor --assignee <vmIdentityPrincipalId>
az role assignment delete --scope $(az group show -n rg-valheim-core --query id -o tsv) --role Reader --assignee <swaAppId>

# smoke test both paths end to end
```

Then Start a server from the page, let it boot, and Save-and-stop. Custom roles are unforgiving about missing read actions, and the failure mode is a deployment that sits at `Running` rather than an obvious 403. If something fails, find the missing action rather than widening the role:

```bash
az monitor activity-log list -g rg-valheim-server --offset 30m \
  --query "[?status.value=='Failed'].{op:operationName.value, msg:properties.statusMessage}" -o json
```

Role definition changes take a minute or two to propagate, and cached ARM tokens hold old permissions for up to ~5 minutes, so re-test rather than trusting the first failure.


## Reconciling with the existing GetRoles API

A Static Web App has one managed Functions app, so one language runtime: the
Valheim controls are Python v1 (`function.json` + `__init__.py`) to match
GetRoles, not a second Node app. Routes come from the `route` property in each
`function.json`, so the paths the page calls are unchanged.

Two consequences of `rolesSource` being set that the original design got wrong:

- **Portal invitations are ignored.** Roles come only from GetRoles, so the
  `valheim` role is granted by the new `VALHEIM_ALLOWLIST` app setting.
- **GetRoles is on the sign-in critical path.** Every dependency in this app is
  imported at cold start, including for GetRoles. That's why the Valheim code
  talks to ARM over REST with `requests` instead of pulling in
  `azure-mgmt-compute`/`-network`/`-resource`, and why `azure-identity` and
  `requests` are imported lazily inside `shared_code/valheim.py:_client()`.
  Signing in to look at photos should not pay for code only the game page uses.
  If you'd rather have the typed SDKs, they work fine -- just watch the gallery's
  cold-start login latency afterwards.

`shared_code/` has no `function.json`, so the runtime treats it as a plain
package rather than a function. Don't rename it to something the indexer might
scan.

### Testing locally

```bash
cd api && pip install -r requirements.txt
swa start ../<thumbsup-output> --api-location .   # emulates auth; /.auth/login/google works
```

The emulator lets you set roles by hand, so you can hit `/valheim` without a
real Google round-trip. Against the deployed site, verify both directions: an
address on `FAMILY_ALLOWLIST` only should get 403 on `/valheim` while the
gallery still works, and an address on both lists should see the page.

