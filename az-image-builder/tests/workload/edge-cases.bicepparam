using '../../workload/main.bicep'

// Two images in one deployment: Linux from a gallery version with custom steps and no scan; Windows with
// hardening and updates off, existing definition, multi-region distribution.
param landingZone = loadJsonContent('../../workload/params/landing-zone.json')
param images = [
  {
    name: 'linux-custom'
    os: 'rhel'
    source: {
      type: 'SharedImageVersion'
      imageVersionId: '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/aib-prod-eus-rg/providers/Microsoft.Compute/galleries/aib_prod_eus_gal/images/rhel-9/versions/1.0.0'
    }
    definition: { name: 'rhel-9-app', publisher: 'contoso', offer: 'rhel', sku: '9-app' }
    software: [ { name: 'installPackages', script: 'linux/software/install-packages.sh', arguments: 'nginx' } ]
    customizers: [ { type: 'Shell', name: 'inlineCheck', inline: [ 'nginx -v' ] } ]
    hardening: { excludeRules: [ 'package_aide_installed' ], scan: false }
  }
  {
    name: 'windows-plain'
    os: 'ws2025'
    source: { type: 'PlatformImage', publisher: 'MicrosoftWindowsServer', offer: 'WindowsServer', sku: '2025-datacenter-azure-edition', version: '26100.4000.250605' }
    definition: { name: 'ws2025-plain', publisher: 'contoso', offer: 'windows-server', sku: '2025-plain', create: false }
    updates: { enabled: false }
    software: [ { name: 'installGit', script: 'windows/software/installGit.ps1', restartAfter: true } ]
    artifactGroups: [ 'git' ]
    hardening: { enabled: false }
    distribution: { regions: [ { name: 'eastus' }, { name: 'westus2', replicaCount: 2, storageAccountType: 'Standard_ZRS' } ] }
  }
]
