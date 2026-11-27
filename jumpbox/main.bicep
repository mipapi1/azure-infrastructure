// Linux jumpbox: spoke network and one Ubuntu 24.04 VM, reached through the hub Bastion.
// hardenedImage picks the STIG-hardened gallery image (image-builder) or the plain Marketplace image.
// Deploy into resource group <env>-rg-<workload>-jumpbox.
import { envCode, name } from '../modules/naming.bicep'

@description('Environment: p (prod) or s (staging).')
param env envCode
@description('Workload name used in every resource name: <env>-<type>-<workload>-<component>.')
param workload string

param sshPublicKey string
param hardenedImage bool = true
param adminUsername string = 'azureuser'
param vmSize string = 'Standard_B2s'
param location string = resourceGroup().location

var subnetPrefix = '10.3.0.0/24'
var vmIpGroup = resourceId(name(env, 'rg', workload, 'hub'), 'Microsoft.Network/ipGroups', name(env, 'ipg', workload, 'jumpbox-vm'))

module spoke '../modules/spoke.bicep' = {
  name: 'spoke-jumpbox'
  params: {
    env: env
    workload: workload
    spoke: 'jumpbox'
    location: location
    addressPrefix: subnetPrefix
    subnets: [{ name: 'vm', addressPrefix: subnetPrefix }]
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
  name: '${env}gal${workload}/ubuntu-2404-stig'
  scope: resourceGroup(name(env, 'rg', workload, 'images'))
}

resource nic 'Microsoft.Network/networkInterfaces@2025-07-01' = {
  name: name(env, 'nic', workload, 'jumpbox')
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
  name: name(env, 'vml', workload, 'jumpbox')
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
        name: name(env, 'osdisk', workload, 'jumpbox')
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id, properties: { deleteOption: 'Delete' } }]
    }
  }
}
