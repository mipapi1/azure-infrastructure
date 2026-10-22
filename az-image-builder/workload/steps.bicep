// Image Builder customizer builders. After bootstrap, scripts are at C:\ImageBuilder\<path> (Windows)
// or /opt/imagebuilder/<path> (Linux), where <path> is relative to workload/scripts.

/////////////
// Windows //
/////////////

@export()
@description('Run a published PowerShell script as SYSTEM. Any terminating error fails the build.')
func runScript(name string, path string, arguments string) object => {
  type: 'PowerShell'
  name: name
  runElevated: true
  runAsSystem: true
  inline: [
    '$ErrorActionPreference = "Stop"'
    '& "C:\\ImageBuilder\\${replace(path, '/', '\\')}" ${arguments}'
  ]
}

@export()
@description('Run inline PowerShell as SYSTEM.')
func inlineStep(name string, lines string[]) object => {
  type: 'PowerShell'
  name: name
  runElevated: true
  runAsSystem: true
  inline: concat(['$ErrorActionPreference = "Stop"'], lines)
}

@export()
@description('Download and hash-verify artifact groups from artifacts.json with the build VM identity.')
func getArtifacts(name string, groups string[], blobEndpoint string, clientId string) object => {
  type: 'PowerShell'
  name: name
  runElevated: true
  runAsSystem: true
  inline: [
    '$ErrorActionPreference = "Stop"'
    'Import-Module "C:\\ImageBuilder\\windows\\lib\\BuildArtifacts.psm1" -Force'
    'Get-BuildArtifacts -ManifestPath "C:\\ImageBuilder\\artifacts.json" -Group ${join(groups, ',')} -BlobEndpoint "${blobEndpoint}" -ClientId "${clientId}"'
  ]
}

@export()
func restart(name string) object => {
  type: 'WindowsRestart'
  name: name
  restartTimeout: '30m'
}

@export()
func windowsUpdate(name string, updateLimit int) object => {
  type: 'WindowsUpdate'
  name: name
  updateLimit: updateLimit
}

///////////
// Linux //
///////////

@export()
@description('Run a published script with bash as root. A non-zero exit fails the build.')
func runShell(name string, path string, arguments string) object => {
  type: 'Shell'
  name: name
  inline: [
    'sudo bash /opt/imagebuilder/${path} ${arguments}'
  ]
}

@export()
@description('Run inline shell commands (/bin/sh -e). Prefix commands that need root with sudo.')
func inlineShell(name string, lines string[]) object => {
  type: 'Shell'
  name: name
  inline: lines
}

@export()
@description('Download and hash-verify artifact groups from artifacts.json with the build VM identity.')
func getArtifactsLinux(name string, groups string[], blobEndpoint string, clientId string) object => {
  type: 'Shell'
  name: name
  inline: [
    'sudo python3 /opt/imagebuilder/linux/lib/get_artifacts.py --manifest /opt/imagebuilder/artifacts.json --group ${join(groups, ',')} --blob-endpoint ${blobEndpoint} --client-id ${clientId}'
  ]
}
