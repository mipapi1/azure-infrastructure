using '../main.bicep'

// Windows Server 2025 member server: STIG (Restricted), Edge. Test build kept out of "latest".
// ./tools/Deploy-ImageBuilder.ps1 -ParamFile workload/params/ws2025.bicepparam

// Written by Deploy-ImageBuilder.ps1 -LandingZone.
param landingZone = loadJsonContent('landing-zone.json')

param tags = {
  environment: 'prod'
  workload: 'platform-image-builder'
  managedBy: 'bicep'
}

param images = [
  {
    name: 'ws2025'
    os: 'ws2025'
    source: {
      type: 'PlatformImage'
      publisher: 'MicrosoftWindowsServer'
      offer: 'WindowsServer'
      sku: '2025-datacenter-azure-edition'
    }
    definition: {
      name: 'ws2025-datacenter'
      publisher: 'contoso'
      offer: 'windows-server'
      sku: '2025-datacenter-azure-edition'
    }
    distribution: {
      excludeFromLatest: true
    }
  }
]
