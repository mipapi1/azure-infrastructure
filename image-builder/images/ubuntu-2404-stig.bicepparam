using '../main.bicep'

// Linux image: Ubuntu 24.04 LTS, STIG-hardened with the SCAP Security Guide. Used by jumpbox/main.bicep.
// Gallery definition ubuntu-2404-stig, template it-ubuntu-2404-stig.
param image = {
  name: 'ubuntu-2404-stig'
  os: 'Linux'
  source: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
}

// Apps: an install script in image-builder/apps/ and its installer. See apps/install-vscode.sh.
param apps = [
  {
    script: 'install-vscode.sh'
    // Download: https://code.visualstudio.com/Download (.deb, x64)
    installer: {
      url: 'https://vscode.download.prss.microsoft.com/dbazure/download/stable/661626d0e72f97806550790a98fb87116c9db825/code_1.148.0-1795526052_amd64.deb'
      sha256: 'da33c10565e17b83f93508a365222f31bba116ab5c9e7bef7f562783943fd513'
    }
  }
]

// SCAP Security Guide STIG profile. Profile, exclusions and the SSG release default to the pinned
// values in main.bicep; override them here, for example: param linuxStigProfile = 'cis_level1_server'
param stig = true

// Your object ID (az ad signed-in-user show --query id -o tsv), so publish.sh can upload.
param publisherIds = ['<publisher-object-id>']

// Build VM. Pick a size your subscription can use in the region:
// az vm list-skus -l eastus --resource-type virtualMachines --query "[?length(restrictions)==\`0\`].name" -o tsv
param buildVmSize = 'Standard_D2as_v4'
// isolated: Image Builder's container runs in snet-container (Dept of State setup).
// proxy: it runs in Image Builder's network and reaches the build VM through a proxy VM in snet-build;
// use it if the container stalls in "Creating" (seen in this subscription's East US testing).
param buildMode = 'isolated'
param proxyVmSize = 'Standard_D2as_v4' // proxy mode only
param buildTimeoutInMinutes = 120
