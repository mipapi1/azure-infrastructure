// One IP group per spoke subnet, named ipg-<spoke>-<subnet>. Firewall rules use them as sources.
// Deployed into rg-hub, next to the firewall policy.

param name string
param subnets array
param location string = resourceGroup().location

resource groups 'Microsoft.Network/ipGroups@2025-07-01' = [
  for s in subnets: {
    name: 'ipg-${name}-${s.name}'
    location: location
    properties: {
      ipAddresses: [s.addressPrefix]
    }
  }
]
