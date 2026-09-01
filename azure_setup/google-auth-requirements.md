# Stage 3 — what is needed to add Google sign-in

## First: you do not need a domain or a certificate

The assumption that a custom domain and a TLS certificate are prerequisites is wrong on
both halves.

**Certificate.** Azure Static Web Apps issues and renews a free managed TLS certificate
for every custom domain automatically. There is nothing to buy from a Norwegian provider
or anyone else, and no certificate to install. A purchased certificate cannot be uploaded
to SWA in the normal flow anyway.

**Domain.** The default `https://<name>.<region>.<n>.azurestaticapps.net` hostname is a
public HTTPS host with a valid certificate. Google accepts it as an authorised redirect
URI without complaint — its restrictions are on `http://`, on IP addresses and on
non-public TLDs, none of which apply. Google sign-in works end to end on the default
hostname.

So a custom domain is a preference, not a requirement. Reasons you might still want one:

- A URL family members can type and recognise, rather than `polite-glacier-0f3a91c2`.
- Stability. The default hostname is tied to the resource; recreate the app and it
  changes, and the Google redirect URI has to change with it.

If you do want one, the Norwegian part is registration and DNS only:

- A `.no` domain is registered through a registrar (Domeneshop, PRO ISP, one.com,
  Uniweb). Norid requires individual registrants to be resident in Norway and to create a
  personal ID against their fødselsnummer; individuals have a lower domain quota than
  organisations. Check the current quota with the registrar.
- A subdomain (`bilder.example.no`) needs one CNAME to the default hostname. Simplest.
- The apex (`example.no`) needs ALIAS/ANAME support at the DNS provider, or move the zone
  to Azure DNS and use an alias record. Norwegian registrars vary on ALIAS support.
- Standard plan allows 6 custom domains.

**Order matters.** Whatever hostname the site will finally use, decide it *before*
creating the Google OAuth client, or register both redirect URIs on the client. Changing
the hostname later without updating Google produces `redirect_uri_mismatch` at sign-in.

---

## The actual requirement list

### 1. Plan
- SKU must be `Standard`. Custom OIDC providers and role assignment via a serverless
  function both require it. Invitation-based roles cap at 25 users; there are ~50 family
  members.

### 2. Google Cloud side
- A Google Cloud project.
- OAuth consent screen: **External**. Scopes `openid`, `profile`, `email` are
  non-sensitive, so no Google verification review is required.
- Publish the app to **In production**. Leaving it in *Testing* caps you at 100 manually
  listed test users and expires refresh tokens after 7 days — family members would be
  re-prompted constantly.
- An **OAuth 2.0 Client ID** of type *Web application*. Record the client ID and secret.
- Authorised redirect URI, exactly:
  `https://<hostname>/.auth/login/google/callback`
  Add one entry per hostname the site will be reachable on (default hostname *and* custom
  domain, if both).
- The `google` segment in that URI is the provider alias from
  `staticwebapp.config.json`. The two must match character for character.

### 3. Azure application settings
Three settings on App B. Never in source control.

| Setting | Contents |
|---|---|
| `GOOGLE_CLIENT_ID` | From the OAuth client |
| `GOOGLE_CLIENT_SECRET` | From the OAuth client |
| `FAMILY_ALLOWLIST` | Comma-separated email addresses, ~50 entries |

Set them out of band rather than through Bicep, so no secret passes through a deployment
or shows up in `what-if`:

```bash
az staticwebapp appsettings set -n $SWA -g $RG --setting-names \
  GOOGLE_CLIENT_ID="..." \
  GOOGLE_CLIENT_SECRET="..." \
  FAMILY_ALLOWLIST="a@gmail.com,b@gmail.com"
```

If you would rather keep it declarative, add `appSettings` to the AVM module with
`@secure()` parameters sourced from Key Vault via `getSecret()` — but for three values
changed once a year, the CLI is the smaller mechanism.

### 4. `staticwebapp.config.json`
As in spec §6.2. The parts that are load-bearing:

- Provider goes under `identityProviders.customOpenIdConnectProviders.google`, **not**
  directly under `identityProviders` as `"google"`. The latter is a legacy shape that
  silently redirects to the Microsoft login page instead of Google.
- Secrets referenced by setting *name* (`clientIdSettingName`,
  `clientSecretSettingName`), never by value.
- `/api/GetRoles` and `/denied` must stay open to `anonymous`. `GetRoles` is called by the
  platform during sign-in, before any role exists; `/denied` prevents a signed-in
  non-family visitor bouncing in a redirect loop.
- `/*` restricted to `["family"]`.
- No `navigationFallback` rewrite. Thumbsup emits real HTML per album; an SPA fallback
  breaks album URLs.
- `X-Robots-Tag: noindex, nofollow` in `globalHeaders`, plus a `robots.txt` with
  `Disallow: /`. Do not enable Thumbsup's `seo-location`, which generates the opposite.

**Registering a custom provider disables every preconfigured provider** — GitHub and Entra
ID sign-in stop working. Expected and fine here; Google is the only intended provider.

### 5. The `GetRoles` function
One function, `api/GetRoles`, in the deployed payload. Called by SWA on each sign-in with
`identityProvider`, `userId`, `userDetails`, `claims`, `accessToken`; returns
`{"roles": ["family"]}` or `{"roles": []}`.

- Reject unless the `email_verified` claim is true. Do not trust `email` alone.
- Normalise Gmail addresses before comparing: lowercase, strip `+tag`, and strip dots in
  the local part for `gmail.com` and `googlemail.com`. `jane.doe@` and `janedoe@` are the
  same mailbox. Skipping this silently locks out family members.
- Normalise the allowlist once at module load, not per request.
- Return empty roles for unknown addresses. Never throw — a 500 here breaks sign-in for
  everyone, not just the unknown caller.
- Verify Python support on *managed* functions (version, and whether the v2 programming
  model is available) before writing it in Python. It is ~30 lines of standard library; if
  Python support is awkward, write it in Node rather than restructuring around a linked
  Function App.

### 6. Deployment consequences
- The `api/` folder must ship in the **same deploy payload** as the gallery content — a
  deploy replaces the whole environment. Manual path becomes:
  `swa deploy ./gallery --api-location ./api --deployment-token "$TOKEN" --env production`
- `allowConfigFileUpdates` must stay `true` (it is, in `main.bicep`), or the auth block in
  the deployed config is ignored.
- Roles are cached in the auth cookie for ~8 hours. Adding someone to `FAMILY_ALLOWLIST`
  takes effect on their next sign-in, not immediately; removing someone leaves them access
  until their cookie expires. Acceptable at annual churn, but know it before debugging it.

### 7. Bicep changes needed
Small. The template as written already sets `Standard`, `stagingEnvironmentPolicy:
'Disabled'`, `allowConfigFileUpdates: true` and `provider: 'None'`. Stage 3 adds only:

- `appSettings` / `functionAppSettings` — if you choose the declarative route over the CLI.
- `customDomains` and `validationMethod` — only if you decide you want a domain.

---

## Order of work

1. Deploy the app (done) and confirm the demo gallery loads on the default hostname.
2. Decide the final hostname. If a custom domain, register and validate it now.
3. Create the Google project, consent screen and OAuth client against that hostname.
4. Set the three application settings.
5. Write `GetRoles`, add `staticwebapp.config.json`, deploy both with the content.
6. Test with three accounts: one on the allowlist, one dotted variant of an allowlist
   address, one not on the list. The third must land on `/denied`, not in a loop.
7. Only then replace the demo photos with family photos.
