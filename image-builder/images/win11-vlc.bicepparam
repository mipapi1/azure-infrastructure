using '../main.bicep'

// Example: Windows 11 Enterprise single session with VLC media player, STIG-hardened.
// Gallery definition win11-vlc, template it-win11-vlc. Copy this file for a new image.
param image = {
  name: 'win11-vlc'
  os: 'Windows'
  // List SKUs: az vm image list-skus -l eastus -p MicrosoftWindowsDesktop -f windows-11 -o table
  source: { publisher: 'MicrosoftWindowsDesktop', offer: 'windows-11', sku: 'win11-25h2-ent', version: 'latest' }
}

param apps = [
  {
    script: 'install-vlc.ps1'
    // Download: https://www.videolan.org/vlc/download-windows.html (SHA256 next to each release)
    installer: {
      url: 'https://get.videolan.org/vlc/3.0.23/win64/vlc-3.0.23-win64.exe'
      sha256: '20ad191348684b470ddc4e05204316f3d8e39655f412b3e392a0eef97639daaf'
    }
  }
]

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
param buildTimeoutInMinutes = 240
