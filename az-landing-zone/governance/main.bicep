metadata name = 'Governance'
metadata description = 'Management group hierarchy aligned to Azure Landing Zones, with a baseline of built-in Azure Policy assignments. Deploy at the parent management group (usually the tenant root group).'

targetScope = 'managementGroup'

import { environmentType } from '../../modules/shared/types.bicep'

@description('Required. Environment. prod builds the live hierarchy; staging builds a separate canary hierarchy to test policy changes first.')
param environment environmentType

@description('Optional. Prefix for management group IDs. Defaults to alz (prod) or alz-canary (staging).')
param prefix string = environment == 'prod' ? 'alz' : 'alz-canary'

@description('Optional. Display name of the intermediate root management group.')
param rootDisplayName string = environment == 'prod' ? 'Azure Landing Zones' : 'Azure Landing Zones (canary)'

@description('Required. Deployment metadata location and location of policy assignment identities.')
param location string

@description('Required. Regions where resources and resource groups may be created.')
param allowedLocations string[]

@description('Optional. Tags every resource group must carry.')
param requiredResourceGroupTags string[] = ['environment', 'workload']

@description('Optional. Resource ID of the central Log Analytics workspace. When set, diagnostic settings and activity log policies are assigned. Deploy the landing zone first, then redeploy governance with this value.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Resource ID of the Windows VM data collection rule from the landing zone. With vmMonitoringIdentityResourceId, assigns the Azure Monitor Agent policy to landing zones.')
param vmDataCollectionRuleResourceId string = ''

@description('Optional. Resource ID of the user-assigned identity the Azure Monitor Agent uses (the landing zone logging identity).')
param vmMonitoringIdentityResourceId string = ''

@description('Optional. Policy enforcement. Defaults to Default (enforced) in prod and DoNotEnforce (audit only) in staging.')
param enforcementMode ('Default' | 'DoNotEnforce') = environment == 'prod' ? 'Default' : 'DoNotEnforce'

@description('Optional. Subscription IDs to place under each management group, keyed by short name (platform, connectivity, identity, management, corp, online, sandbox, decommissioned).')
param subscriptionPlacement object = {}

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

// ---------------------------------------------------------------------------
// Management groups
// ---------------------------------------------------------------------------

var children = [
  { key: 'platform', displayName: 'Platform', parent: prefix }
  { key: 'landingzones', displayName: 'Landing zones', parent: prefix }
  { key: 'sandbox', displayName: 'Sandbox', parent: prefix }
  { key: 'decommissioned', displayName: 'Decommissioned', parent: prefix }
]
var grandchildren = [
  { key: 'connectivity', displayName: 'Connectivity', parent: '${prefix}-platform' }
  { key: 'identity', displayName: 'Identity', parent: '${prefix}-platform' }
  { key: 'management', displayName: 'Management', parent: '${prefix}-platform' }
  { key: 'corp', displayName: 'Corp', parent: '${prefix}-landingzones' }
  { key: 'online', displayName: 'Online', parent: '${prefix}-landingzones' }
]

module rootGroup 'br/public:avm/res/management/management-group:0.2.0' = {
  name: '${uniqueString(deployment().name)}-mg-root'
  params: {
    name: prefix
    displayName: rootDisplayName
    location: location
    enableTelemetry: enableTelemetry
  }
}

module childGroups 'br/public:avm/res/management/management-group:0.2.0' = [
  for mg in children: {
    name: '${uniqueString(deployment().name)}-mg-${mg.key}'
    scope: managementGroup(mg.parent)
    params: {
      name: '${prefix}-${mg.key}'
      displayName: mg.displayName
      parentId: mg.parent
      location: location
      enableTelemetry: enableTelemetry
    }
    dependsOn: [rootGroup]
  }
]

module grandchildGroups 'br/public:avm/res/management/management-group:0.2.0' = [
  for mg in grandchildren: {
    name: '${uniqueString(deployment().name)}-mg-${mg.key}'
    scope: managementGroup(mg.parent)
    params: {
      name: '${prefix}-${mg.key}'
      displayName: mg.displayName
      parentId: mg.parent
      location: location
      enableTelemetry: enableTelemetry
    }
    dependsOn: [childGroups]
  }
]

// Subscription placement. Deployed at the parent so a subscription can move between groups.
resource placements 'Microsoft.Management/managementGroups/subscriptions@2023-04-01' = [
  for p in items(subscriptionPlacement): {
    name: '${prefix}-${p.key}/${p.value}'
    scope: tenant()
    dependsOn: [childGroups, grandchildGroups]
  }
]

// ---------------------------------------------------------------------------
// Policy assignments (built-in definitions only)
// ---------------------------------------------------------------------------

var builtIn = '/providers/Microsoft.Authorization/policyDefinitions'
var builtInSet = '/providers/Microsoft.Authorization/policySetDefinitions'
var role = {
  contributor: '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c'
  logAnalyticsContributor: '/providers/Microsoft.Authorization/roleDefinitions/92aaf0da-9dab-42b6-94a3-d43ce8d16293'
  monitoringContributor: '/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa'
  tagContributor: '/providers/Microsoft.Authorization/roleDefinitions/4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
  vmContributor: '/providers/Microsoft.Authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
  managedIdentityOperator: '/providers/Microsoft.Authorization/roleDefinitions/f1a07417-d97a-45cb-824c-7a7467783830'
}

var baselineAssignments = concat(
  [
    {
      name: 'Audit-MCSB'
      displayName: 'Microsoft cloud security benchmark'
      scope: prefix
      definitionId: '${builtInSet}/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
      parameters: {}
      roles: []
    }
    {
      name: 'Deny-Locations'
      displayName: 'Allowed locations'
      scope: prefix
      definitionId: '${builtIn}/e56962a6-4747-49cd-b67b-bf8b01975c4c'
      parameters: { listOfAllowedLocations: { value: union(allowedLocations, ['global']) } }
      roles: []
    }
    {
      name: 'Deny-RG-Locations'
      displayName: 'Allowed locations for resource groups'
      scope: prefix
      definitionId: '${builtIn}/e765b5de-1225-4ba3-bd56-1ac6695af988'
      parameters: { listOfAllowedLocations: { value: allowedLocations } }
      roles: []
    }
    {
      name: 'Deny-NIC-PublicIP'
      displayName: 'Network interfaces should not have public IPs'
      scope: '${prefix}-corp'
      definitionId: '${builtIn}/83a86a26-fd1f-447c-b59d-e51f44264114'
      parameters: {}
      roles: []
    }
    {
      name: 'Deny-Storage-http'
      displayName: 'Secure transfer to storage accounts should be enabled'
      scope: '${prefix}-landingzones'
      definitionId: '${builtIn}/404c3081-a854-4457-ae30-26a93ef643f9'
      parameters: { effect: { value: 'Deny' } }
      roles: []
    }
  ],
  flatten(map(requiredResourceGroupTags, t => [
    {
      name: take('Require-RG-${t}', 24)
      displayName: 'Require tag "${t}" on resource groups'
      scope: prefix
      definitionId: '${builtIn}/96670d01-0a4d-4649-9c89-2d3abc0a5025'
      parameters: { tagName: { value: t } }
      roles: []
    }
    {
      name: take('Inherit-${t}', 24)
      displayName: 'Inherit tag "${t}" from the resource group if missing'
      scope: prefix
      definitionId: '${builtIn}/ea3f2387-9b95-492a-a190-fcdc54f7b070'
      parameters: { tagName: { value: t } }
      roles: [role.tagContributor]
    }
  ])),
  empty(logAnalyticsWorkspaceResourceId)
    ? []
    : [
        {
          // Safety net: any resource deployed without diagnostic settings gets them.
          name: 'Deploy-Diag-LogsCat'
          displayName: 'Send resource logs to the central Log Analytics workspace'
          scope: prefix
          definitionId: '${builtInSet}/f5b29bc4-feca-4cc6-a58a-772dd5e290a5'
          parameters: { logAnalytics: { value: logAnalyticsWorkspaceResourceId } }
          roles: [role.logAnalyticsContributor, role.monitoringContributor]
        }
        {
          name: 'Deploy-AzActivity-Log'
          displayName: 'Send the activity log to the central Log Analytics workspace'
          scope: prefix
          definitionId: '${builtIn}/2465583e-4e78-4c15-b6be-a36cbc7c8b0f'
          parameters: {
            logAnalytics: { value: logAnalyticsWorkspaceResourceId }
            logsEnabled: { value: 'True' }
          }
          roles: [role.logAnalyticsContributor, role.monitoringContributor]
        }
      ],
  empty(vmDataCollectionRuleResourceId) || empty(vmMonitoringIdentityResourceId)
    ? []
    : [
        {
          name: 'Deploy-VM-Monitoring'
          displayName: 'Enable Azure Monitor Agent and baseline data collection on VMs'
          scope: '${prefix}-landingzones'
          definitionId: '${builtInSet}/924bfe3a-762f-40e7-86dd-5c8b95eb09e6'
          parameters: {
            dcrResourceId: { value: vmDataCollectionRuleResourceId }
            bringYourOwnUserAssignedManagedIdentity: { value: true }
            restrictBringYourOwnUserAssignedIdentityToSubscription: { value: false }
            userAssignedIdentityResourceId: { value: vmMonitoringIdentityResourceId }
            enableProcessesAndDependencies: { value: false }
            scopeToSupportedImages: { value: false }
          }
          roles: [
            role.vmContributor
            role.logAnalyticsContributor
            role.monitoringContributor
            role.managedIdentityOperator
          ]
        }
      ]
)

module policyAssignments 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = [
  for a in baselineAssignments: {
    name: '${uniqueString(deployment().name)}-pa-${a.name}'
    scope: managementGroup(a.scope)
    params: {
      name: a.name
      displayName: a.displayName
      description: '${a.displayName}. Part of the platform governance baseline.'
      metadata: { assignedBy: 'Platform governance (az-landing-zone/governance)' }
      policyDefinitionId: a.definitionId
      parameters: a.parameters
      identity: empty(a.roles) ? 'None' : 'SystemAssigned'
      roleDefinitionIds: a.roles
      managementGroupId: a.scope
      location: location
      enforcementMode: enforcementMode
      nonComplianceMessages: [{ message: '${a.displayName}. See docs/DECISIONS.md for exemptions.' }]
      enableTelemetry: enableTelemetry
    }
    dependsOn: [grandchildGroups]
  }
]

@description('Management group IDs keyed by short name.')
output managementGroupIds object = union(
  { root: prefix },
  toObject(children, c => c.key, c => '${prefix}-${c.key}'),
  toObject(grandchildren, c => c.key, c => '${prefix}-${c.key}')
)
