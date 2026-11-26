using 'main.bicep'

// Every installer below is a { url, sha256 } pair. publish.sh downloads each one, checks the SHA256
// and uploads it to the image builder storage account; builds read it from there. After changing
// one, run publish.sh, delete the templates and deploy again.

// Your object ID (az ad signed-in-user show --query id -o tsv), so publish.sh can upload.
param publisherIds = ['<publisher-object-id>']

// Apps ------------------------------------------------------------------------------------------
// To add an app: put an install script in image-builder/apps/ (copy install-vscode.ps1 or .sh),
// add it here with its installer's download URL and SHA256, run publish.sh, then replace the
// templates. The script gets the installer's local path ($args[0] on Windows, $1 on Ubuntu).
// No installer to download? Use url: '' and sha256: ''.
param windowsApps = [
  {
    script: 'install-vscode.ps1'
    // Download: https://code.visualstudio.com/Download (System Installer, x64)
    installer: {
      url: 'https://vscode.download.prss.microsoft.com/dbazure/download/stable/661626d0e72f97806550790a98fb87116c9db825/VSCodeSetup-x64-1.148.0.exe'
      sha256: '80e3c1814125f141afd5e196c22a831abfc5fdf4ee4087cf6b08c692e649f79c'
    }
  }
]
param linuxApps = [
  {
    script: 'install-vscode.sh'
    // Download: https://code.visualstudio.com/Download (.deb, x64)
    installer: {
      url: 'https://vscode.download.prss.microsoft.com/dbazure/download/stable/661626d0e72f97806550790a98fb87116c9db825/code_1.148.0-1795526052_amd64.deb'
      sha256: 'da33c10565e17b83f93508a365222f31bba116ab5c9e7bef7f562783943fd513'
    }
  }
]

// Windows 11 AVD image ------------------------------------------------------------------------
// true: DISA STIG hardening (stig.ps1 lists what is left out and why).
param windowsStig = false

// GPO folders from the DISA package, matched as "DoD <name> ...". Others in the October 2026
// package include 'Google Chrome' and 'Office 2019-M365 Apps'.
param windowsStigGpos = [
  'Windows 11'
  'Windows Defender Firewall'
  'Microsoft Defender Antivirus'
  'Microsoft Edge'
]

// Settings the GPO package doesn't set: TLS protocols and ciphers, .NET strong crypto, DEP,
// PowerShell 2.0, password expiry, auditing.
param windowsStigSupplemental = true

// DISA releases a GPO package each quarter. New one: change the URL and its SHA256 (Get-FileHash).
// Download: https://public.cyber.mil/stigs/gpo/ (files at dl.dod.cyber.mil/wp-content/uploads/stigs/zip/)
param windowsStigPackage = {
  url: 'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_STIG_GPO_Package_October_2026.zip'
  sha256: 'C8A093C0656CCF6D71D98A9556AA37E0F4E31574AC2AAC86F76D7D14355167BA'
}

// Microsoft LGPO, which imports the GPOs.
// Download: https://www.microsoft.com/download/details.aspx?id=55319 (Security Compliance Toolkit)
param windowsLgpo = {
  url: 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip'
  sha256: 'CB7159D134A0A1E7B1ED2ADA9A3CE8CE8F4DE391D14403D55438AF824247CC55'
}

// DISA SCAP Compliance Checker, installed in the image for scans. Empty url: not installed.
// Download: https://public.cyber.mil/stigs/scap/ (Windows bundle: scc-<version>_Windows_bundle.zip)
param windowsScc = {
  url: 'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/scc-5.15_Windows_bundle.zip'
  sha256: 'A537A0F9A39CCC2231818709F8BB5F8F9B9CBFC2EC0D44DBBFABBE35D4F558BA'
}

// Ubuntu 24.04 image (always hardened) ---------------------------------------------------------
// SCAP Security Guide profile: 'stig', or another SSG profile such as 'cis_level1_server'.
param linuxStigProfile = 'stig'

// Rules not applied. Each one is a finding; stig-linux.sh explains these two.
param linuxStigExcludes = [
  'sudo_remove_nopasswd'
  'sudo_require_authentication'
]

// SCAP Security Guide release and its SHA256 (sha256sum).
// Download: https://github.com/ComplianceAsCode/content/releases (scap-security-guide-<version>.zip)
param linuxSsg = {
  url: 'https://github.com/ComplianceAsCode/content/releases/download/v0.1.82/scap-security-guide-0.1.82.zip'
  sha256: '765e84bdce7f9055f9b9c2dd0ee2b713d4255f8eec94eac6d35ea4973c28919c'
}

// DISA SCC for Linux (zip containing a .deb). The download needs a DoD login, so host it yourself.
// Download: https://public.cyber.mil/stigs/scap/ (Ubuntu bundle)
// OpenSCAP (`sudo stig-scan`) is always installed.
param linuxScc = {
  url: ''
  sha256: ''
}
