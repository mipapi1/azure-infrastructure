using '../main.bicep'

// Windows Server 2022 member server: STIG (Standard), admin tooling.
// ./tools/Deploy-ImageBuilder.ps1 -ParamFile workload/params/ws2022.bicepparam

// Written by Deploy-ImageBuilder.ps1 -LandingZone.
param landingZone = loadJsonContent('landing-zone.json')

param tags = {
  environment: 'prod'
  workload: 'platform-image-builder'
  managedBy: 'bicep'
}

param images = [
  {
    name: 'ws2022'
    os: 'ws2022'
    source: {
      type: 'PlatformImage'
      publisher: 'MicrosoftWindowsServer'
      offer: 'WindowsServer'
      sku: '2022-datacenter-azure-edition'
    }
    definition: {
      name: 'ws2022-datacenter'
      publisher: 'contoso'
      offer: 'windows-server'
      sku: '2022-datacenter-azure-edition'
    }
    artifactGroups: [ 'git', 'azure-cli', 'python' ]
    software: [
      { name: 'installGit', script: 'windows/software/installGit.ps1' }
      { name: 'installAzureCli', script: 'windows/software/installAzCli.ps1' }
      { name: 'installPython', script: 'windows/software/installPython.ps1' }
    ]
    hardening: {
      profile: 'Standard'
    }
  }
]
