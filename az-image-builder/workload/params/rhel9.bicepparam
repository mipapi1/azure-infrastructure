using '../main.bicep'

// Red Hat Enterprise Linux 9: DISA STIG via SCAP Security Guide. RHEL 10: sku 10-lvm-gen2 (check with az vm image list-skus).
// ./tools/Deploy-ImageBuilder.ps1 -ParamFile workload/params/rhel9.bicepparam

// Written by Deploy-ImageBuilder.ps1 -LandingZone.
param landingZone = loadJsonContent('landing-zone.json')

param tags = {
  environment: 'prod'
  workload: 'platform-image-builder'
  managedBy: 'bicep'
}

param images = [
  {
    name: 'rhel9'
    os: 'rhel'
    source: {
      type: 'PlatformImage'
      publisher: 'RedHat'
      offer: 'RHEL'
      sku: '9-lvm-gen2'
    }
    definition: {
      name: 'rhel-9'
      publisher: 'contoso'
      offer: 'rhel'
      sku: '9-lvm-gen2'
    }
    software: [
      { name: 'installPackages', script: 'linux/software/install-packages.sh', arguments: 'jq tmux' }
    ]
    hardening: {
      stigProfile: 'stig'
      // excludeRules: [ 'rule_id' ]   // document every exclusion
    }
  }
]
