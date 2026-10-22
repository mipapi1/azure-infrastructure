# Spoke network

Spoke virtual network for a workload landing zone. Used by `az-avd` and `az-aks`.

- One NSG per subnet with two baseline rules at priority 4096: deny inbound from the internet, and deny outbound SSH/RDP to the virtual network (management goes through Bastion). Subnet rules from `securityRules` come first.
- A route table that sends `0.0.0.0/0` to the hub firewall, with BGP propagation off. Set `routeToFirewall: false` on subnets that only hold private endpoints.
- DNS through the firewall DNS proxy, so private endpoint names resolve from the hub zones.
- Peering in both directions with forwarded traffic allowed; gateway transit when `hub.useRemoteGateways` is set.
- Default outbound access disabled on every subnet.

Built from the AVM virtual network, network security group and route table modules.

## Parameters

<!-- BEGIN_PARAMS -->
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes |  | Name of the spoke virtual network. |
| `location` | string | no | computed | Location for all resources. |
| `addressPrefixes` | string[] | yes |  | Address space of the spoke virtual network. |
| `subnets` | spokeSubnetType[] | yes |  | Subnets to create. |
| `hub` | hubReferenceType | no |  | Hub connection details. Leave empty for an isolated spoke (no peering, no forced tunnelling). |
| `useHubDnsProxy` | bool | no | `true` | Use the hub firewall as DNS server (firewall DNS proxy). Defaults to true when a hub is set. |
| `dnsServers` | string[] | no | `[]` | Custom DNS servers. Overrides the hub DNS proxy when set. |
| `additionalRoutes` | array | no | `[]` | Additional routes on the spoke route table. |
| `ddosProtectionPlanResourceId` | string | no |  | Resource ID of a DDoS protection plan to associate. |
| `diagnosticSettings` | diagnosticSettingFullType[] | no |  | Diagnostic settings for the virtual network and NSGs. |
| `lock` | lockType | no |  | Lock applied to every resource in this module. |
| `roleAssignments` | roleAssignmentType[] | no |  | Role assignments on the virtual network. |
| `tags` | tagsType | yes |  | Tags applied to every resource. |
| `enableTelemetry` | bool | no | `true` | Enable AVM usage telemetry. |

| Output | Type | Description |
|---|---|---|
| `resourceId` | string | Resource ID of the spoke virtual network. |
| `name` | string | Name of the spoke virtual network. |
| `subnetResourceIds` | object | Subnet resource IDs keyed by subnet name. |
| `routeTableResourceId` | string | Resource ID of the spoke route table, empty when there is no hub. |
<!-- END_PARAMS -->
