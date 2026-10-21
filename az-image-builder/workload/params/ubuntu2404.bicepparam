using '../main.bicep'

// Ubuntu Server 24.04 LTS: DISA STIG via SCAP Security Guide, Azure CLI, extra packages.
// ./tools/Deploy-ImageBuilder.ps1 -ParamFile workload/params/ubuntu2404.bicepparam

// Written by Deploy-ImageBuilder.ps1 -LandingZone.
param landingZone = loadJsonContent('landing-zone.json')

param tags = {
  environment: 'prod'
  workload: 'platform-image-builder'
  managedBy: 'bicep'
}

param images = [
  {
    name: 'ubuntu2404'
    os: 'ubuntu'
    source: {
      type: 'PlatformImage'
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
    }
    definition: {
      name: 'ubuntu-2404'
      publisher: 'contoso'
      offer: 'ubuntu-server'
      sku: '24.04-lts'
    }
    software: [
      { name: 'installPackages', script: 'linux/software/install-packages.sh', arguments: 'jq unzip' }
      { name: 'installAzureCli', script: 'linux/software/install-azure-cli.sh' }
    ]
    hardening: {
      stigProfile: 'stig'
    }
  }
]
