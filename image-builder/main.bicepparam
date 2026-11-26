using 'main.bicep'

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
param windowsStigPackage = {
  url: 'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_STIG_GPO_Package_October_2026.zip'
  sha256: 'C8A093C0656CCF6D71D98A9556AA37E0F4E31574AC2AAC86F76D7D14355167BA'
}

// DISA SCAP Compliance Checker, installed in the image for scans. Empty url: not installed.
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

// SCAP Security Guide release (github.com/ComplianceAsCode/content/releases) and its SHA256.
param linuxSsg = {
  version: '0.1.82'
  sha256: '765e84bdce7f9055f9b9c2dd0ee2b713d4255f8eec94eac6d35ea4973c28919c'
}

// DISA SCC for Linux (zip containing a .deb). The download needs a DoD login, so host it yourself.
// OpenSCAP (`sudo stig-scan`) is always installed.
param linuxScc = {
  url: ''
  sha256: ''
}
