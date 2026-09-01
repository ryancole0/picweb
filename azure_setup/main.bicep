// picweb, initial deployment.
//
// This template creates ONLY the Static Web App resource, on the default
// *.azurestaticapps.net hostname. No auth, no custom domain, no API, no
// repository integration (§8 of the project spec: provider stays 'None' and
// content is pushed with a deployment token).
//
// Everything auth-related — appSettings, GOOGLE_CLIENT_ID/SECRET,
// FAMILY_ALLOWLIST — is deliberately absent. See docs/google-auth-requirements.md.

//(optional) Confirm the AVM module version pin in `main.bicep` first:
// ```bash
// az rest --method get --url https://mcr.microsoft.com/v2/bicep/avm/res/web/static-site/tags/list
// ```


targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Required. Name of the Static Web App. Becomes part of the default hostname.')
@minLength(1)
@maxLength(40)
param name string

@description('Optional. Region. Microsoft.Web/staticSites is only available in these five. westeurope is the closest to Norway; static content is served from a global edge regardless, this only pins the control plane and (later) the managed function.')
@allowed([
  'westeurope'
  'eastasia'
  'centralus'
  'eastus2'
  'westus2'
])
param location string = 'westeurope'

@description('''Optional. Plan.
- Standard (~$9/mo): 500 MB per environment, custom OIDC, unlimited users via a roles function.
- Free ($0): 250 MB per environment, no custom OIDC, invitation-based roles capped at 25 users.
Standard is required for the end state (spec §3). Deploying Standard now means the size you
measure in stage 2 is the size you get in stage 4. A later Free -> Standard flip is a
non-destructive in-place SKU update if you would rather not pay during stage 2.''')
@allowed([
  'Free'
  'Standard'
])
param sku string = 'Standard'

@description('Optional. Preview/staging environments. Disabled on App B — a preview environment is an unauthenticated copy of the gallery on a guessable hostname.')
@allowed([
  'Enabled'
  'Disabled'
])
param stagingEnvironmentPolicy string = 'Disabled'

@description('Optional. Resource tags.')
param tags object = {
  workload: 'picweb'
  app: 'gallery'
  managedBy: 'bicep'
}

@description('Optional. AVM telemetry deployment.')
param enableTelemetry bool = true

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

// VERIFY THE PIN BEFORE FIRST DEPLOY (spec §7). Current published tags:
//   az rest --method get --url https://mcr.microsoft.com/v2/bicep/avm/res/web/static-site/tags/list
// or in VS Code, type the colon and press Ctrl+Space for the version list.
module gallery 'br/public:avm/res/web/static-site:0.9.0' = {
  name: 'swa-gallery-${uniqueString(deployment().name, location)}'
  params: {
    name: name
    location: location
    sku: sku
    tags: tags
    enableTelemetry: enableTelemetry

    // Content is deployed with a deployment token, not by ARM-driven GitHub
    // integration. Leaving provider at 'None' and omitting repositoryUrl /
    // branch / repositoryToken is the whole point of spec §8 — do not add them.
    provider: 'None'

    stagingEnvironmentPolicy: stagingEnvironmentPolicy

    // Required so a staticwebapp.config.json shipped in the deployed content is
    // honoured. Without it the auth block added in stage 3 is silently ignored.
    allowConfigFileUpdates: true
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Static Web App resource name — pass to `az staticwebapp secrets list -n`.')
output staticWebAppName string = gallery.outputs.name

@description('Default hostname, e.g. gentle-sand-0a1b2c3d4.westeurope.5.azurestaticapps.net')
output defaultHostname string = gallery.outputs.defaultHostname

@description('Full https URL of the site.')
output siteUrl string = 'https://${gallery.outputs.defaultHostname}'

@description('Resource ID, for scoping role assignments to this app.')
output resourceId string = gallery.outputs.resourceId

@description('Resource group of the deployed app.')
output resourceGroupName string = gallery.outputs.resourceGroupName

// The AVM module does not output the deployment token — AVM modules never emit
// secrets. Fetch it at deploy time:
//   az staticwebapp secrets list -n <name> -g <rg> --query properties.apiKey -o tsv
