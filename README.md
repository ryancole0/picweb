# Thumbsup gallery, local -> Azure

Goal: prove the generator, the theme, and the keywords-to-albums mapping before any
Azure resource exists. No auth, no deployment.

## Environment
Local development in Ubuntu/WSL, deploy to Static Web App in Azure



## Layout

```
picweb/
  build.sh          docker run wrapper
  serve.sh          local static server
  deploy.sh         update existing SWA with new source
  thumbsup.json     all build options
  prune-tags.py     remove all tags not contained in tags-allowed.toml
  tags-allowed.toml list of allowed tags
  azure_setup/      Bicep files to deploy SWA (without source)
  photos/           your demo photos (gitignored)
  gallery/          generated output (gitignored)
  .cache/           generated thumbsup.db + log (gitignored)
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
chmod +x build.sh serve.sh prune-tags.py
mkdir -p photos
```

### Configure Azure
* requires an exisitng subscription
```bash
RGNAME="rg-picweb"
az group create -n $RGNAME -l norwayeast

az deployment group create \
  -g $RGNAME \
  -f azure_setup/main.bicep \
  -p azure_setup/main.bicepparam \
  --query properties.outputs
```

Record `staticWebAppName` and `defaultHostname` from the output.


## Demo photos

Use 30–60 throwaway or public-domain JPEGs — **not** family photos. Stage 2 puts this
same output on a public hostname before auth exists.

Organise them into folders so you can bulk-tag by folder:

```
photos/
  bergen/
  hytta/
  jul-2019/
```

Deliberately include one folder name with a space and one with `æ`/`ø`/`å`. Those
become album names, then URLs, and URL-encoding of non-ASCII album paths is exactly
the kind of thing that works locally and breaks on a CDN.



## Tagging
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

## Build and view
```bash
./build.sh          # or: Ctrl+Shift+B in VS Code
./serve.sh          # run locally open http://localhost:8080
./deploy.sh         # deploy static web app
```

VS Code forwards the port to Windows automatically; the URL works in your normal
browser. First build pulls a ~340 MB image and processes serially-ish; later builds
are incremental and only touch changed files.


## Gotchas

- **Changing `thumb-size`, `large-size`, `photo-quality` or `gm-args` does not
  regenerate existing media.** Thumbsup only reprocesses files whose *source* changed.
  To re-test sizing: `rm -rf gallery .cache && ./build.sh` (VS Code task
  "gallery: rebuild from scratch"). Settle the numbers now — stage 4 against 5 GB is
  not where you want to discover you need a rebuild.
- **Videos are off** (`include-videos: false`). A single re-encoded clip can eat a
  meaningful slice of the 500 MB per-environment cap. Turn them on deliberately, if at all.
- **Dates render in the container's timezone.** `build.sh` mounts `/etc/localtime`, so
  set the WSL timezone correctly (`sudo dpkg-reconfigure tzdata`) or dates are GMT.
- **No `seo-location`.** It generates `robots.txt` and `sitemap.xml`; App B wants the
  opposite (§2).
- **`cleanup: true`** deletes output media no longer referenced by any album. Keeps the
  deployable size honest. It never touches `photos/`.
