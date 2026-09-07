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