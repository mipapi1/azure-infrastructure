metadata name = 'Azure Kubernetes Service'
metadata description = 'Private AKS cluster on a hub-connected spoke: Entra RBAC, CNI Overlay with Cilium, workload identity, Key Vault, Container Registry, Managed Prometheus and Grafana, Container Insights and Flux GitOps.'

targetScope = 'subscription'

import { environmentType, hubReferenceType, lockFor, monitoringReferenceType, tagsType } from '../modules/shared/types.bicep'
import { compactName, regionShortNames } from '../modules/shared/naming.bicep'
import { accessType, aksMonitoringType, aksNetworkType, clusterType, gitOpsType, nodePoolType } from 'types.bicep'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Required. Environment.')
param environment environmentType

@description('Required. Region for every resource.')
param location string

@description('Optional. Workload name used in resource names.')
param workload string = 'aks'

@description('Required. Tags applied to every resource.')
param tags tagsType

@description('Required. Hub connection details (az-landing-zone output "hub").')
param hub hubReferenceType

@description('Required. Central monitoring (az-landing-zone output "monitoring"). The data collection endpoint is required for private ingestion.')
param monitoring monitoringReferenceType

@description('Optional. Hub firewall policy (az-landing-zone output firewallPolicyResourceId). When set, the AKS egress rules are added to it.')
param firewallPolicyResourceId string = ''

@description('Optional. Priority of the AKS rule collection group in the hub firewall policy.')
param firewallRulePriority int = 1100

@description('Optional. Extra FQDNs the nodes may reach over HTTPS, for example Git hosting or public chart and image registries that are not mirrored into the registry.')
param allowedEgressFqdns string[] = []

@description('Required. Spoke network.')
param network aksNetworkType

@description('Required. Cluster and node pools.')
param cluster clusterType

@description('Required. Access.')
param access accessType

@description('Optional. GitOps with the Flux extension. Leave empty to manage workloads another way.')
param gitOps gitOpsType?

@description('Optional. Monitoring options.')
param aksMonitoring aksMonitoringType = {}

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var isProd = environment == 'prod'
var lock = lockFor(environment)
var baseName = '${workload}-${environment}-${regionShortNames[location]}'
var clusterName = '${baseName}-aks'
var defaultZones = isProd ? [1, 2, 3] : []

var rgNames = {
  network: '${baseName}-network-rg'
  cluster: '${baseName}-rg'
}

var dnsZoneRg = hub.privateDnsZoneResourceGroupResourceId
var dnsZoneRgSegments = split(dnsZoneRg, '/')
var dnsZone = {
  aks: '${dnsZoneRg}/providers/Microsoft.Network/privateDnsZones/privatelink.${location}.azmk8s.io'
  acr: '${dnsZoneRg}/providers/Microsoft.Network/privateDnsZones/privatelink${az.environment().suffixes.acrLoginServer}'
  kv: '${dnsZoneRg}/providers/Microsoft.Network/privateDnsZones/privatelink${az.environment().suffixes.keyvaultDns}'
  prometheus: '${dnsZoneRg}/providers/Microsoft.Network/privateDnsZones/privatelink.${location}.prometheus.monitor.azure.com'
  grafana: '${dnsZoneRg}/providers/Microsoft.Network/privateDnsZones/privatelink.grafana.azure.com'
}

var diagnosticSettings = [
  {
    name: 'to-central-law'
    workspaceResourceId: monitoring.logAnalyticsWorkspaceResourceId
  }
]

var roleIds = {
  networkContributor: '4d97b98b-1d4f-4787-a291-c67834d212e7'
  privateDnsZoneContributor: 'b12aa53e-6015-4669-85d0-8515ebb3ae7f'
  managedIdentityOperator: 'f1a07417-d97a-45cb-824c-7a7467783830'
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  aksRbacClusterAdmin: 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'
  aksRbacReader: '7f6c6a51-bcf8-42ba-9220-52d62157d7db'
  aksClusterUser: '4abbcc35-e782-43d8-92c5-2d3f1bd2253f'
}

@description('Builds a role assignment for an Entra group.')
func groupRole(principalId string, roleId string) object => {
  principalId: principalId
  principalType: 'Group'
  roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
}

@description('Converts a node pool parameter to the managed cluster agent pool shape.')
func agentPool(pool nodePoolType, mode string, subnetId string, defaultZones int[], tags object) object => {
  name: pool.name
  mode: mode
  vmSize: pool.vmSize
  osType: 'Linux'
  osSKU: 'AzureLinux'
  type: 'VirtualMachineScaleSets'
  enableAutoScaling: true
  count: pool.?minCount ?? (mode == 'System' ? 2 : 1)
  minCount: pool.?minCount ?? (mode == 'System' ? 2 : 1)
  maxCount: pool.?maxCount ?? 5
  maxPods: pool.?maxPods ?? 110
  osDiskType: pool.?osDiskType ?? 'Ephemeral'
  osDiskSizeGB: pool.?osDiskSizeGB ?? 128
  availabilityZones: pool.?availabilityZones ?? defaultZones
  enableEncryptionAtHost: true
  enableNodePublicIP: false
  vnetSubnetResourceId: subnetId
  nodeLabels: pool.?nodeLabels
  // The system pool only runs critical add-ons; workloads go to user pools.
  nodeTaints: mode == 'System' ? ['CriticalAddonsOnly=true:NoSchedule'] : pool.?nodeTaints
  scaleSetPriority: (pool.?spot ?? false) ? 'Spot' : 'Regular'
  scaleSetEvictionPolicy: (pool.?spot ?? false) ? 'Delete' : null
  upgradeSettings: { maxSurge: '33%' }
  tags: tags
}

// ---------------------------------------------------------------------------
// Resource groups and identities
// ---------------------------------------------------------------------------

module resourceGroups 'br/public:avm/res/resources/resource-group:0.4.4' = [
  for rg in items(rgNames): {
    name: '${uniqueString(deployment().name, location)}-rg-${rg.key}'
    params: {
      name: rg.value
      location: location
      lock: lock
      tags: tags
      enableTelemetry: enableTelemetry
    }
  }
]

// Control plane identity. A user-assigned identity lets the network and DNS
// permissions exist before the cluster is created.
module controlPlaneIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: '${uniqueString(deployment().name, location)}-id-cp'
  scope: resourceGroup(rgNames.cluster)
  params: {
    name: '${baseName}-id-controlplane'
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups]
}

module kubeletIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: '${uniqueString(deployment().name, location)}-id-kubelet'
  scope: resourceGroup(rgNames.cluster)
  params: {
    name: '${baseName}-id-kubelet'
    location: location
    roleAssignments: [
      {
        principalId: controlPlaneIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          roleIds.managedIdentityOperator
        )
      }
    ]
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

module spoke '../modules/network/spoke-network/main.bicep' = {
  name: '${uniqueString(deployment().name, location)}-spoke'
  scope: resourceGroup(rgNames.network)
  params: {
    name: '${baseName}-vnet'
    location: location
    addressPrefixes: network.addressPrefixes
    hub: hub
    subnets: [
      {
        name: 'snet-aks-nodes'
        addressPrefix: network.nodeSubnetPrefix
      }
      {
        name: 'snet-private-endpoints'
        addressPrefix: network.privateEndpointSubnetPrefix
        routeToFirewall: false
        securityRules: [
          {
            name: 'allow-nodes-https'
            properties: {
              access: 'Allow'
              direction: 'Inbound'
              priority: 100
              protocol: 'Tcp'
              sourceAddressPrefix: network.nodeSubnetPrefix
              sourcePortRange: '*'
              destinationAddressPrefix: network.privateEndpointSubnetPrefix
              destinationPortRange: '443'
            }
          }
          {
            name: 'allow-hub-https'
            properties: {
              access: 'Allow'
              direction: 'Inbound'
              priority: 110
              protocol: 'Tcp'
              sourceAddressPrefix: 'VirtualNetwork'
              sourcePortRange: '*'
              destinationAddressPrefix: network.privateEndpointSubnetPrefix
              destinationPortRange: '443'
              description: 'Operators and pipelines reach the registry, vault and Grafana from peered networks.'
            }
          }
        ]
      }
    ]
    // UDR outbound needs the control plane to manage the subnet and route table.
    roleAssignments: [
      {
        principalId: controlPlaneIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          roleIds.networkContributor
        )
      }
    ]
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups]
}

module routeTableAccess 'br/public:avm/ptn/authorization/resource-role-assignment:0.1.2' = {
  name: '${uniqueString(deployment().name, location)}-ra-rt'
  scope: resourceGroup(rgNames.network)
  params: {
    resourceId: resourceId(
      subscription().subscriptionId,
      rgNames.network,
      'Microsoft.Network/routeTables',
      '${baseName}-vnet-rt'
    )
    // The identity is created in this deployment, so its principal ID is only known at run time.
    #disable-next-line what-if-short-circuiting
    principalId: controlPlaneIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleIds.networkContributor
    enableTelemetry: enableTelemetry
  }
  dependsOn: [spoke]
}

// A private cluster with a central private DNS zone needs the control plane to
// write its API server record there.
module dnsZoneAccess 'br/public:avm/ptn/authorization/resource-role-assignment:0.1.2' = {
  name: '${uniqueString(deployment().name, location)}-ra-dns'
  scope: resourceGroup(dnsZoneRgSegments[2], dnsZoneRgSegments[4])
  params: {
    resourceId: dnsZone.aks
    #disable-next-line what-if-short-circuiting
    principalId: controlPlaneIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleIds.privateDnsZoneContributor
    enableTelemetry: enableTelemetry
  }
}

var firewallPolicySegments = split(firewallPolicyResourceId, '/')
var loginHost = replace(replace(az.environment().authentication.loginEndpoint, 'https://', ''), '/', '')

// Required egress: https://learn.microsoft.com/azure/aks/outbound-rules-control-egress
module firewallRules '../modules/network/firewall-rule-collection-group/main.bicep' = if (!empty(firewallPolicyResourceId)) {
  name: '${uniqueString(deployment().name, location)}-afw-rules'
  scope: resourceGroup(firewallPolicySegments[2], firewallPolicySegments[4])
  params: {
    firewallPolicyName: last(firewallPolicySegments)
    name: '${baseName}-rcg'
    priority: firewallRulePriority
    ruleCollections: [
      {
        name: 'aks-network'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'azure-monitor'
            ipProtocols: ['TCP']
            sourceAddresses: [network.nodeSubnetPrefix]
            destinationAddresses: ['AzureMonitor']
            destinationPorts: ['443']
          }
        ]
      }
      {
        name: 'aks-application'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 200
        action: { type: 'Allow' }
        rules: concat(
          [
            {
              ruleType: 'ApplicationRule'
              name: 'aks-fqdn-tag'
              protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
              sourceAddresses: [network.nodeSubnetPrefix]
              fqdnTags: ['AzureKubernetesService']
            }
            {
              ruleType: 'ApplicationRule'
              name: 'aks-addons'
              protocols: [{ protocolType: 'Https', port: 443 }]
              sourceAddresses: [network.nodeSubnetPrefix]
              targetFqdns: [
                // Azure Policy, Defender, Flux and Entra token endpoints.
                'data.policy.${az.environment().suffixes.storage}'
                'store.policy.${az.environment().suffixes.storage}'
                '*.ods.opinsights.azure.com'
                '*.oms.opinsights.azure.com'
                '*.monitoring.azure.com'
                '${location}.dp.kubernetesconfiguration.azure.com'
                loginHost
              ]
            }
          ],
          empty(allowedEgressFqdns)
            ? []
            : [
                {
                  ruleType: 'ApplicationRule'
                  name: 'workload-egress'
                  protocols: [{ protocolType: 'Https', port: 443 }]
                  sourceAddresses: [network.nodeSubnetPrefix]
                  targetFqdns: allowedEgressFqdns
                }
              ]
        )
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

var registryName = compactName(workload, environment, location, 'cr', uniqueString(subscription().id, workload), 50)

module registry 'br/public:avm/res/container-registry/registry:0.13.1' = {
  name: '${baseName}-acr-deploy'
  scope: resourceGroup(rgNames.cluster)
  params: {
    name: registryName
    location: location
    acrSku: 'Premium'
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Disabled'
    exportPolicyStatus: 'disabled'
    zoneRedundancy: isProd ? 'Enabled' : 'Disabled'
    retentionPolicyStatus: 'enabled'
    retentionPolicyDays: 30
    privateEndpoints: [
      {
        name: '${registryName}-pe'
        subnetResourceId: spoke.outputs.subnetResourceIds['snet-private-endpoints']
        privateDnsZoneGroup: { privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: dnsZone.acr }] }
        tags: tags
      }
    ]
    roleAssignments: [
      {
        principalId: kubeletIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.acrPull)
      }
    ]
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// ---------------------------------------------------------------------------
// Cluster
// ---------------------------------------------------------------------------

var nodeSubnetId = spoke.outputs.subnetResourceIds['snet-aks-nodes']
var gitOpsEnabled = !empty(gitOps) && (gitOps.?enabled ?? true)

module managedCluster 'br/public:avm/res/container-service/managed-cluster:0.14.0' = {
  name: '${uniqueString(deployment().name, location)}-aks'
  scope: resourceGroup(rgNames.cluster)
  params: {
    name: clusterName
    location: location
    kubernetesVersion: cluster.?kubernetesVersion
    skuTier: cluster.?skuTier ?? (isProd ? 'Standard' : 'Free')
    managedIdentities: { userAssignedResourceIds: [controlPlaneIdentity.outputs.resourceId] }
    identityProfile: {
      kubeletidentity: {
        resourceId: kubeletIdentity.outputs.resourceId
        clientId: kubeletIdentity.outputs.clientId
        objectId: kubeletIdentity.outputs.principalId
      }
    }
    nodeResourceGroup: '${baseName}-nodes-rg'
    nodeResourceGroupProfile: { restrictionLevel: 'ReadOnly' }

    // Identity and access: Entra ID only, authorization with Azure RBAC.
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      tenantID: tenant().tenantId
    }
    disableLocalAccounts: true
    enableRBAC: true
    enableOidcIssuerProfile: true
    securityProfile: {
      workloadIdentity: { enabled: true }
      imageCleaner: { enabled: true, intervalHours: 168 }
      defender: {
        logAnalyticsWorkspaceResourceId: monitoring.logAnalyticsWorkspaceResourceId
        securityMonitoring: { enabled: true }
      }
    }

    // Network: private API server, CNI Overlay with the Cilium data plane, all egress through the hub.
    publicNetworkAccess: 'Disabled'
    apiServerAccessProfile: {
      enablePrivateCluster: true
      enablePrivateClusterPublicFQDN: false
      privateDNSZone: dnsZone.aks
    }
    networkPlugin: 'azure'
    networkPluginMode: 'overlay'
    networkDataplane: 'cilium'
    networkPolicy: 'cilium'
    podCidr: network.?podCidr ?? '192.168.0.0/16'
    serviceCidr: network.?serviceCidr ?? '172.16.0.0/16'
    dnsServiceIP: network.?dnsServiceIP ?? '172.16.0.10'
    outboundType: 'userDefinedRouting'
    loadBalancerSku: 'standard'

    primaryAgentPoolProfiles: [agentPool(cluster.systemPool, 'System', nodeSubnetId, defaultZones, tags)]
    agentPools: map(cluster.?userPools ?? [], p => agentPool(p, 'User', nodeSubnetId, defaultZones, tags))
    autoScalerProfile: {
      'balance-similar-node-groups': 'true'
      expander: 'least-waste'
      'skip-nodes-with-system-pods': 'true'
    }

    // Upgrades: patch versions and node images inside the maintenance windows.
    autoUpgradeProfile: {
      upgradeChannel: cluster.?upgradeChannel ?? 'patch'
      nodeOSUpgradeChannel: cluster.?nodeOSUpgradeChannel ?? 'NodeImage'
    }
    maintenanceConfigurations: [
      {
        name: 'aksManagedAutoUpgradeSchedule'
        maintenanceWindow: {
          durationHours: 4
          startTime: cluster.?maintenanceStartTime ?? '02:00'
          utcOffset: cluster.?maintenanceUtcOffset ?? '+00:00'
          schedule: { weekly: { dayOfWeek: cluster.?maintenanceDay ?? 'Sunday', intervalWeeks: 1 } }
        }
      }
      {
        name: 'aksManagedNodeOSUpgradeSchedule'
        maintenanceWindow: {
          durationHours: 4
          startTime: cluster.?maintenanceStartTime ?? '02:00'
          utcOffset: cluster.?maintenanceUtcOffset ?? '+00:00'
          schedule: { weekly: { dayOfWeek: cluster.?maintenanceDay ?? 'Sunday', intervalWeeks: 1 } }
        }
      }
    ]

    // Add-ons
    azurePolicyEnabled: true
    enableKeyvaultSecretsProvider: true
    enableSecretRotation: true
    webApplicationRoutingEnabled: true
    defaultIngressControllerType: 'Internal'
    workloadAutoScalerProfile: { keda: { enabled: true } }
    enableStorageProfileDiskCSIDriver: true
    enableStorageProfileFileCSIDriver: true
    enableStorageProfileSnapshotController: true
    costAnalysisEnabled: cluster.?skuTier != 'Free' && isProd

    // Monitoring: Container Insights with Entra auth and Managed Prometheus; rules in the monitoring module.
    omsAgentEnabled: true
    omsAgentUseAADAuth: true
    monitoringWorkspaceResourceId: monitoring.logAnalyticsWorkspaceResourceId
    azureMonitorProfile: {
      metrics: {
        enabled: true
        kubeStateMetrics: { metricLabelsAllowlist: '', metricAnnotationsAllowList: '' }
      }
    }
    diagnosticSettings: [
      {
        name: 'to-central-law'
        workspaceResourceId: monitoring.logAnalyticsWorkspaceResourceId
        logAnalyticsDestinationType: 'Dedicated'
        // kube-audit (all reads) is left out for cost; kube-audit-admin covers changes.
        logCategoriesAndGroups: [
          { category: 'kube-apiserver' }
          { category: 'kube-audit-admin' }
          { category: 'kube-controller-manager' }
          { category: 'kube-scheduler' }
          { category: 'cluster-autoscaler' }
          { category: 'guard' }
          { category: 'cloud-controller-manager' }
        ]
        metricCategories: [{ category: 'AllMetrics' }]
      }
    ]

    // The configuration "name" below is read by the AVM extension module although its type omits it.
    #disable-next-line BCP037
    fluxExtension: gitOpsEnabled
      ? {
          releaseTrain: 'Stable'
          configurationSettings: {
            'multiTenancy.enforce': 'false'
            'helm-controller.enabled': 'true'
            'source-controller.enabled': 'true'
            'kustomize-controller.enabled': 'true'
            'notification-controller.enabled': 'true'
            'image-automation-controller.enabled': 'false'
            'image-reflector-controller.enabled': 'false'
          }
          fluxConfigurations: [
            {
              // The GitRepository and root Kustomization are named after the configuration.
              name: 'cluster-config'
              namespace: 'flux-system'
              scope: 'cluster'
              sourceKind: 'GitRepository'
              gitRepository: {
                url: gitOps.?repositoryUrl
                repositoryRef: { branch: gitOps.?branch ?? 'main' }
                syncIntervalInSeconds: 300
                timeoutInSeconds: 180
              }
              kustomizations: {
                cluster: {
                  path: gitOps.?clusterPath ?? './az-aks/gitops/clusters/${environment}'
                  prune: true
                  syncIntervalInSeconds: 600
                  timeoutInSeconds: 600
                  retryIntervalInSeconds: 120
                }
              }
            }
          ]
        }
      : null

    roleAssignments: concat(
      map(access.adminGroupObjectIds, g => groupRole(g, roleIds.aksRbacClusterAdmin)),
      map(access.?readerGroupObjectIds ?? [], g => groupRole(g, roleIds.aksRbacReader)),
      // Cluster User lets the groups download a kubeconfig; Kubernetes permissions come from the RBAC roles.
      map(
        union(access.adminGroupObjectIds, access.?readerGroupObjectIds ?? []),
        g => groupRole(g, roleIds.aksClusterUser)
      )
    )
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [routeTableAccess, dnsZoneAccess, firewallRules, registry]
}

// ---------------------------------------------------------------------------
// Workload secrets: Key Vault and the External Secrets identity
// ---------------------------------------------------------------------------

module externalSecretsIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: '${uniqueString(deployment().name, location)}-id-eso'
  scope: resourceGroup(rgNames.cluster)
  params: {
    name: '${baseName}-id-external-secrets'
    location: location
    federatedIdentityCredentials: [
      {
        name: 'external-secrets'
        issuer: managedCluster.outputs.oidcIssuerUrl!
        subject: 'system:serviceaccount:external-secrets:external-secrets'
        audiences: ['api://AzureADTokenExchange']
      }
    ]
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

var keyVaultName = compactName(workload, environment, location, 'kv', uniqueString(subscription().id, workload), 24)

module keyVault 'br/public:avm/res/key-vault/vault:0.14.2' = {
  name: '${baseName}-kv-deploy'
  scope: resourceGroup(rgNames.cluster)
  params: {
    name: keyVaultName
    location: location
    sku: 'standard'
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    enableVaultForDeployment: false
    enableVaultForDiskEncryption: false
    enableVaultForTemplateDeployment: false
    publicNetworkAccess: 'Disabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Deny' }
    privateEndpoints: [
      {
        name: '${keyVaultName}-pe'
        subnetResourceId: spoke.outputs.subnetResourceIds['snet-private-endpoints']
        privateDnsZoneGroup: { privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: dnsZone.kv }] }
        tags: tags
      }
    ]
    roleAssignments: [
      {
        principalId: externalSecretsIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          roleIds.keyVaultSecretsUser
        )
      }
    ]
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// ---------------------------------------------------------------------------
// Monitoring
// ---------------------------------------------------------------------------

module clusterMonitoring '../modules/aks/monitoring/main.bicep' = {
  name: '${uniqueString(deployment().name, location)}-monitoring'
  scope: resourceGroup(rgNames.cluster)
  params: {
    namePrefix: baseName
    location: location
    clusterName: clusterName
    logAnalyticsWorkspaceResourceId: monitoring.logAnalyticsWorkspaceResourceId
    dataCollectionEndpointResourceId: monitoring.?dataCollectionEndpointResourceId ?? ''
    privateEndpointSubnetResourceId: spoke.outputs.subnetResourceIds['snet-private-endpoints']
    prometheusPrivateDnsZoneResourceId: dnsZone.prometheus
    deployGrafana: aksMonitoring.?grafana ?? true
    grafanaPrivateDnsZoneResourceId: dnsZone.grafana
    grafanaPublicNetworkAccess: aksMonitoring.?grafanaPublicNetworkAccess ?? 'Disabled'
    grafanaZoneRedundancy: isProd
    grafanaAdminGroupObjectIds: access.adminGroupObjectIds
    grafanaViewerGroupObjectIds: access.?grafanaViewerGroupObjectIds ?? []
    deployAlerts: aksMonitoring.?alerts ?? true
    actionGroupResourceId: monitoring.?actionGroupResourceId ?? ''
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [managedCluster]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the cluster.')
output clusterResourceId string = managedCluster.outputs.resourceId

@description('Name of the cluster.')
output clusterName string = managedCluster.outputs.name

@description('Resource group of the cluster.')
output clusterResourceGroupName string = rgNames.cluster

@description('OIDC issuer URL for workload identity federation.')
output oidcIssuerUrl string = managedCluster.outputs.oidcIssuerUrl!

@description('Login server of the container registry.')
output registryLoginServer string = registry.outputs.loginServer

@description('Name of the container registry.')
output registryName string = registry.outputs.name

@description('URI of the workload key vault.')
output keyVaultUri string = keyVault.outputs.uri

@description('Client ID of the External Secrets identity (service account annotation azure.workload.identity/client-id).')
output externalSecretsClientId string = externalSecretsIdentity.outputs.clientId

@description('Resource ID of the Azure Monitor workspace.')
output monitorWorkspaceResourceId string = clusterMonitoring.outputs.monitorWorkspaceResourceId

@description('Resource ID of Managed Grafana.')
output grafanaResourceId string = clusterMonitoring.outputs.grafanaResourceId
