# Thumbsup gallery as SWA

Minimal gallery website, hosted as a Static Web App, using Google Oauth for login and a custom Python function to restrict access to a specific set of users

## Environment
Local development in Ubuntu/WSL, deploy to Static Web App in Azure, auth from Google

## Layout

```
picweb/
  update_swa_auth.sh    update environment variables in SWA used for authentication, including list of allowed users 
  build.sh              build html source for gallery application based on photos in photos/, using tags as gallery labels
  serve.sh              run local server (will have to disable some auth for this to work)
  deploy.sh             update existing SWA with new source
  thumbsup.json         all build options for Thumbsup
  prune-tags.py         script to whitelist photo tags from tags-allowed.toml
  tags-allowed.toml     list of allowed tags
  size-check.sh         helper shell script to check if size of website exceeds SWA limits
  api/                  custom Python function to whitelist access to specific users 
  azure_setup/          Bicep files to deploy raw SWA 
  static/               Static denied.html and staticwebapp.config.json files

Ignored folders:
  photos/               input photos 
  gallery/              generated html source 
  .cache/               generated thumbsup.db + log 
  .secrets/             client id, client secret, and list of allowed email addresses
```

## Setup

### Configure local compute (Ubuntu)
* install dependencies
```bash
# az cli
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
# requires exiftool
sudo apt install libimage-exiftool-perl
# pruning tags requires uv/python 3.11+
curl -LsSf https://astral.sh/uv/install.sh | sh
# deploy requires npm 18+
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | sudo gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
  | sudo tee /etc/apt/sources.list.d/nodesource.list
sudo apt update && sudo apt install -y nodejs
```
* install dependencies for api
```
uv pip install --target ".python_packages/lib/site-packages" \
  --python-platform x86_64-manylinux2014 \
  --python-version 3.11 \
  --link-mode=copy \
  -r api/requirements.txt
```

* modify permissions
```bash
chmod +x build.sh serve.sh deploy.sh size-check.sh update_swa_auth.sh prune-tags.py
mkdir -p photos
```

## Initial Azure Setup
### Create empty resource group and Static Web App
* requires an exisitng subscription
```bash
RGNAME="rg-picweb"
az group create -n $RGNAME -l westeurope

az deployment group create \
  -g $RGNAME \
  -f azure_setup/main.bicep \
  -p azure_setup/main.bicepparam \
  --query properties.outputs
```

### Update SWA with custom domain
Need to manually facilitate handshake by generating a token from Azure for a TXT record, then setting that TXT record on the domain server with domain host, then add CNAME to default hostname
* initiate token generation from Azure (note the no-wait)
```bash
RG=rg-picweb
SWA=swa-picweb-gallery
HOST=family.colecreations.no

az staticwebapp hostname set -n "$SWA" -g "$RG" \
  --hostname "$HOST" \
  --validation-method dns-txt-token \
  --no-wait
```
* run the following to check if token creation is finished (Status -> Validating)
```
az staticwebapp hostname show -n "$SWA" -g "$RG" \
  --hostname "$HOST" \
  --query "{status:status, token:validationToken}" -o table
```
* At DNS registrar create a 
  * a TXT record on _dnsauth.family.colecreations.no, using only the token value output from previous step
  * a CNAME record on family, pointing to the default URI for the static web app: <>.azurestaticapps.net
* Re-run hostname show until status is Ready
```bash
az staticwebapp hostname show -n "$SWA" -g "$RG" \
  --hostname "$HOST" \
  --query "{status:status, token:validationToken}" -o table
```

### Google Auth
* OAuth consent screen / Google Auth Platform
  * User type: External.
  * Authorized domains: add colecreations.no
  * Leave in Testing and only listed test users can sign in 
* Credentials → Create credentials → OAuth client ID → Web application.
  * Authorized JavaScript origins: leave empty
  * Authorized redirect URIs: add both.
    * https://family.colecreations.no/.auth/login/google/callback
    * https://<swa-default-hostname>/.auth/login/google/callback
* Data Access -> Add or remove scopes -> add the following non-sensitive scopes:
  * openid
  * ../auth/userinfo.profile
  * ../auth/userinfo.email


### Configure Static Web App to use Oauth
The static web app source includes a config file that specifies which environment variables to use to fetch secrets and other configuration from the runtime environment.  We need to populate those variables in the runtime environment so they can be utilized, using secrets from `.secrets/` and `family-allowlist.txt`
```bash
./update_swa_auth.sh
```

### Privacy controls for domain
Add the following DNS records to prevent others from sending email that look like they come from the site (SPF + DMARC), and prevent anyone from claiming the domain with a DKIM signature.
* SPF
  * domain-name | TXT | "v=spf1 -all" 
* DMARC
  * _dmarc.domain-name  TXT  "v=DMARC1; p=reject; rua=mailto:dmarc@somewhere-you-read.example" 
* DKIM
  * *._domainkey.domain-name  TXT  "v=DKIM1; p="

# Update the website
## Generating gallery photos

Copy desired photos into photos folder.  If desired, create folder structure to implicitly assign tags based on folder contents.  Recommend stripping tags first.  Otherwise, use existing photo tags but strip undesired tags using prune_tags.py script.

### Tagging
- Reading tags:
```bash
exiftool -Keywords -s -r photos
```
- Pruning tags to list of allowed tags in toml file:
```
# dryrun
./prune-tags.py photos/            
# run
./prune-tags.py photos/ --apply
```
- Applying tags by folder:
```bash
for d in photos/*/; do
  name="$(basename "$d")"
  find "$d" -maxdepth 1 -type f -iname '*.identifier' -print -delete
  exiftool -overwrite_original -Keywords="$name" "photos/$name"
done
```
- Manual tagging:
```bash
exiftool -overwrite_original -Keywords+="favoritter" photos/bergen/IMG_0001.jpg
exiftool -overwrite_original -Keywords+="Steder/Bergen" photos/bergen/IMG_0002.jpg
```

## Build html and view
```bash
./build.sh --full-rebuild         # or: Ctrl+Shift+B in VS Code
./serve.sh          # run locally open http://localhost:8080
./deploy.sh         # deploy static web app
```

## Update allowed user list
* edit `.secrets/family-allowlist.txt` to add/remove users
* run `./update_swa_auth.sh` to update "list of allowed users" environment variable in SWA


# Play the server world locally

This guide downloads the latest copy of the server world from blob storage and loads it as a local world in the Valheim client. Use it to play offline, host from your own PC for a night, or check the state of a backup.

The blob container is the source of truth for the server. Restoring the world locally is **read-only** on the Azure side and changes nothing for the next server start. Pushing a locally played world *back* to the server is a separate step, described at the end.

## 1. Make sure the server is off

The copy in blob storage is only as fresh as the last sync. When the server is running, that means up to one game save behind (30 minutes by default). After a normal "Save and stop", the blob copy is final.

Check the state on `/valheim`, or from the CLI:

```bash
az vm show -g rg-valheim-server -n valheim-vm --query name -o tsv 2>/dev/null \
  && echo "server is running: stop it first for the final copy" \
  || echo "server is off"
```

## 2. One-time setup: give yourself read access to the world

Shared-key access is disabled on the storage account, so every download uses your Entra ID login. Subscription Owner does **not** include data-plane access. Grant yourself read on the `valheim` container once:

```bash
source .env   # provides VALHEIM_STORAGE_ACCOUNT
SA="$VALHEIM_STORAGE_ACCOUNT"

SA_ID=$(az storage account show -n "$SA" -g rg-valheim-core --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)

az role assignment create \
  --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Storage Blob Data Reader" \
  --scope "$SA_ID/blobServices/default/containers/valheim"
```

The role assignment can take a few minutes to take effect. If the download in the next step returns `AuthorizationPermissionMismatch`, wait and retry.

## 3. Download the latest world

```bash
source .env
SA="$VALHEIM_STORAGE_ACCOUNT"
OUT="$HOME/valheim-restore/$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT"

az storage blob download-batch --auth-mode login --account-name "$SA" \
  -s valheim --pattern 'worlds_local/*' -d "$OUT" -o none

# Sanity check: local file count should match the blob count
remote=$(az storage blob list --auth-mode login --account-name "$SA" \
  -c valheim --prefix worlds_local/ --num-results '*' --query 'length(@)' -o tsv)
local=$(find "$OUT/worlds_local" -type f | wc -l)
echo "remote: $remote   downloaded: $local"
ls -la "$OUT/worlds_local"
```

The download lands in `$OUT/worlds_local/`, laid out exactly as the server stored it. The server runs with its save directory at `/config`, which is the same structure the client uses, so nothing needs renaming.

The world name is whatever `VALHEIM_WORLD_NAME` is set to on the SWA (default `Midgard`). You should see files carrying that name.

Keep the timestamped folder. It is a free point-in-time backup.

## 4. Copy it into the game's save folder

Valheim keeps local worlds here:

| Client | Folder |
|---|---|
| Windows | `%USERPROFILE%\AppData\LocalLow\IronGate\Valheim\worlds_local\` |
| Windows, seen from WSL | `/mnt/c/Users/<you>/AppData/LocalLow/IronGate/Valheim/worlds_local/` |
| Linux (Steam native) | `~/.config/unity3d/IronGate/Valheim/worlds_local/` |

**Close Valheim first.** The game rewrites its world list on exit.

From WSL, to a Windows install:

```bash
WIN_USER=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r')
DEST="/mnt/c/Users/$WIN_USER/AppData/LocalLow/IronGate/Valheim/worlds_local"
mkdir -p "$DEST"

# Back up whatever is there now; a same-named local world would be overwritten.
[ -n "$(ls -A "$DEST" 2>/dev/null)" ] && \
  cp -a "$DEST" "${DEST}.bak-$(date +%Y%m%d-%H%M)"

cp -a "$OUT/worlds_local/." "$DEST/"
```

The trailing `/.` copies the *contents*. If the world doesn't appear in the game, check that you haven't ended up with `worlds_local/worlds_local/`.

Don't rename the files to avoid a name clash with an existing local world. The world name is also stored inside the world data. Move the old world aside instead, which the backup step above already does.

## 5. Load it in Valheim

1. Update the client in Steam first. The server installs the newest game build on every boot, so the world may have been saved by a newer version than your client. An older client can refuse to load it.
2. Start Game → pick your character → Start.
3. In the world list, make sure you are viewing **local** worlds, not cloud worlds, and select the server world.
4. Leave **Start server** unticked to play alone. Tick it to host for others from your PC; they join via your IP or Steam friends.

Characters are not part of the world. They live on each player's own machine (`characters_local`), so everyone keeps their own inventory and skills exactly as they had them on the server.

## Optional: push a locally played world back to the server

Only do this if you deliberately want the server to continue from your local progress. It replaces the server world.

1. Make sure the server is **off** (step 1), and nobody starts it while you work.
2. Your account needs **Storage Blob Data Contributor** on the container. Use the step 2 command with that role instead of Reader.
3. Clear the remote world and upload the local one. Clearing first matters: stale generation files left in blob would be restored next to your new ones.

```bash
SRC="/mnt/c/Users/$WIN_USER/AppData/LocalLow/IronGate/Valheim/worlds_local"

az storage blob delete-batch --auth-mode login --account-name "$SA" \
  -s valheim --pattern 'worlds_local/*'

az storage blob upload-batch --auth-mode login --account-name "$SA" \
  -d valheim/worlds_local -s "$SRC" -o none
```

Upload only the server world's files. If your local `worlds_local` holds other worlds, copy the server world into a clean folder and upload that instead.

Versioning and the 30-day soft delete keep the previous server world recoverable from the portal if this goes wrong. Remove the Contributor role afterwards if you don't need it day to day.