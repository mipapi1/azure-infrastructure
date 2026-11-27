// One IP group per spoke subnet, named <env>-ipg-<workload>-<spoke>-<subnet>. Firewall rules use
// them as sources. Deployed into the hub resource group, next to the firewall policy.
import { envCode, name } from 'naming.bicep'

param env envCode
param workload string
param spoke string
param subnets array
param location string = resourceGroup().location

resource groups 'Microsoft.Network/ipGroups@2025-07-01' = [
  for s in subnets: {
    name: name(env, 'ipg', workload, '${spoke}-${s.name}')
    location: location
    properties: {
      ipAddresses: [s.addressPrefix]
    }
  }
]
