using './main.bicep'

// Must be globally reasonable within the region; the default hostname is
// derived from this plus a random partition suffix.
param name = 'swa-picweb-gallery'

param location = 'westeurope'

// 'Free' for a cheaper stage 2 (250 MB cap), 'Standard' to match the end state.
param sku = 'Standard'

param stagingEnvironmentPolicy = 'Disabled'

param tags = {
  workload: 'picweb'
  app: 'gallery'
  managedBy: 'bicep'
  stage: '2-no-auth'
}
