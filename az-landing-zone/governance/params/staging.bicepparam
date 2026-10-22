using '../main.bicep'

// Canary hierarchy (alz-canary-*): policy changes land here first, audit only.
param environment = 'staging'
param location = 'eastus'
param allowedLocations = ['eastus', 'westus2']
