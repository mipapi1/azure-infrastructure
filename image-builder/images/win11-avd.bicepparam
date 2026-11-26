using '../main.bicep'

// AVD session host image: Windows 11 multi-session with Microsoft 365 Apps.
// Gallery definition win11-avd, template it-win11-avd. Used by avd/main.bicep.
param image = {
  name: 'win11-avd'
  os: 'Windows'
  source: { publisher: 'MicrosoftWindowsDesktop', offer: 'office-365', sku: 'win11-25h2-avd-m365', version: 'latest' }
}

// Apps: an install script in image-builder/apps/ and its installer. See apps/install-vscode.ps1.
param apps = [
  {
    script: 'install-vscode.ps1'
    // Download: https://code.visualstudio.com/Download (System Installer, x64)
    installer: {
      url: 'https://vscode.download.prss.microsoft.com/dbazure/download/stable/661626d0e72f97806550790a98fb87116c9db825/VSCodeSetup-x64-1.148.0.exe'
      sha256: '80e3c1814125f141afd5e196c22a831abfc5fdf4ee4087cf6b08c692e649f79c'
    }
  }
]

// true: DISA STIG (stig.ps1 lists what is left out and why). The GPO list, the GPO package, LGPO
// and SCC default to the pinned values in main.bicep; override them here, for example:
//   param windowsStigGpos = ['Windows 11', 'Windows Defender Firewall', 'Microsoft Defender Antivirus', 'Microsoft Edge', 'Office 2019-M365 Apps']
param stig = false

// Your object ID (az ad signed-in-user show --query id -o tsv), so publish.sh can upload.
param publisherIds = ['<publisher-object-id>']
