using '../main.bicep'

// Windows 11 multi-session AVD image: STIG (Restricted), Edge + Chrome, Microsoft 365 STIG, SCAP scanner.
// ./tools/Deploy-ImageBuilder.ps1 -ParamFile workload/params/win11-avd.bicepparam

// Written by Deploy-ImageBuilder.ps1 -LandingZone.
param landingZone = loadJsonContent('landing-zone.json')

param tags = {
  environment: 'prod'
  workload: 'platform-image-builder'
  managedBy: 'bicep'
}

param images = [
  {
    name: 'win11-avd'
    os: 'win11'
    source: {
      type: 'PlatformImage'
      publisher: 'MicrosoftWindowsDesktop'
      offer: 'office-365'
      sku: 'win11-25h2-avd-m365'
    }
    definition: {
      name: 'win11-avd'
      publisher: 'contoso'
      offer: 'windows-11'
      sku: 'win11-25h2-avd-m365'
    }
    build: {
      vmSize: 'Standard_D8ds_v5'
      timeoutInMinutes: 360
    }
    artifactGroups: [ 'scap' ]
    software: [
      { name: 'installScap', script: 'windows/software/installScap.ps1' }
    ]
    hardening: {
      profile: 'Restricted'
      browsers: [ 'edge', 'chrome' ]
      additionalStigPackages: [ 'Office 2019-M365 Apps' ]
      disconnectedSessionLimit: '90m'
      // legalNotice: { caption: '<Organization> Monitoring Consent Notice', text: '<banner text>' }
    }
  }
]
