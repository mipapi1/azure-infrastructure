// Linux jumpbox: spoke network and one Ubuntu 24.04 VM, reached through the hub Bastion.
// hardenedImage picks the STIG-hardened gallery image (image-builder) or the plain Marketplace image.
// Deploy into resource group rg-jumpbox.

param sshPublicKey string
param hardenedImage bool = true
param adminUsername string = 'azureuser'
param vmSize string = 'Standard_B2s'
param location string = resourceGroup().location

var subnetPrefix = '10.3.0.0/24'
var vmIpGroup = resourceId('rg-hub', 'Microsoft.Network/ipGroups', 'ipg-jumpbox-snet-vm')

module spoke '../modules/spoke.bicep' = {
  name: 'spoke-jumpbox'
  params: {
    name: 'jumpbox'
    location: location
    addressPrefix: subnetPrefix
    subnets: [{ name: 'snet-vm', addressPrefix: subnetPrefix }]
    rulePriority: 400
    ruleCollections: [
      {
        name: 'jumpbox-application'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'ubuntu-updates'
            protocols: [{ protocolType: 'Http', port: 80 }, { protocolType: 'Https', port: 443 }]
            sourceIpGroups: [vmIpGroup]
            targetFqdns: ['azure.archive.ubuntu.com', 'archive.ubuntu.com', 'security.ubuntu.com', 'esm.ubuntu.com', 'motd.ubuntu.com']
          }
        ]
      }
    ]
  }
}

resource image 'Microsoft.Compute/galleries/images@2024-03-03' existing = {
  name: 'gal_images/ubuntu-2404-stig'
  scope: resourceGroup('rg-image-builder')
}

resource nic 'Microsoft.Network/networkInterfaces@2025-07-01' = {
  name: 'nic-jumpbox'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: '${spoke.outputs.vnetId}/subnets/snet-vm' }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: 'vm-jumpbox'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
    osProfile: {
      computerName: 'jumpbox'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
      }
    }
    storageProfile: {
      imageReference: hardenedImage
        ? { id: image.id }
        : { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id, properties: { deleteOption: 'Delete' } }]
    }
  }
}
