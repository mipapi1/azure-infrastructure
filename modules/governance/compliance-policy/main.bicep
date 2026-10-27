metadata name = 'Compliance policy'
metadata description = 'NIST SP 800-53 Rev. 5 regulatory compliance initiative (built-in) and the platform guardrails initiative (custom shared key exception policy plus built-ins) at one management group. No AVM covers policy definitions or initiatives.'

targetScope = 'managementGroup'

@description('Optional. Management group the definitions live on and the initiatives are assigned to. Defaults to the deployment scope.')
param managementGroupId string = managementGroup().name

@description('Required. Location of the deployment metadata.')
param location string

@description('Optional. Assign the NIST SP 800-53 Rev. 5 initiative. Defaults to true.')
param assignNist bool = true

@description('Optional. Parameter values for the NIST initiative, in assignment format ({ name: { value: x } }). Defaults to the initiative defaults.')
param nistParameters object = {}

@description('Optional. Enforcement of both assignments. DoNotEnforce (default) evaluates and reports without blocking or remediating.')
param enforcementMode ('Default' | 'DoNotEnforce') = 'DoNotEnforce'

@description('Optional. Effect of the guardrail policies. Audit (default) reports; Deny blocks non-compliant changes once enforcementMode is Default.')
param guardrailEffect ('Audit' | 'Deny' | 'Disabled') = 'Audit'

@description('Optional. Values the shared-key-exception tag may take. Each value names a documented exception (D-025).')
param sharedKeyExceptionValues string[] = ['fslogix-cloud-cache']

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

var nistInitiativeId = tenantResourceId(
  'Microsoft.Authorization/policySetDefinitions',
  '179d1daa-458f-4e47-8086-2a68d0d6c38f'
)

// Shared key access only with a documented exception. The built-in "Storage accounts should
// prevent shared key access" (8c6a50c6) has no exception path, so this replaces it here.
resource sharedKeyPolicy 'Microsoft.Authorization/policyDefinitions@2025-01-01' = {
  name: 'platform-storage-shared-key-exception'
  properties: {
    displayName: 'Storage accounts should disable shared key access unless they carry an approved shared-key-exception tag'
    description: 'Shared key (account key) access must be disabled. The only exceptions are accounts tagged shared-key-exception with an approved value, such as the FSLogix Cloud Cache blob account that can only authenticate with a key.'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: { category: 'Storage', version: '1.0.0', source: 'platform-guardrails' }
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
      exceptionValues: {
        type: 'Array'
        defaultValue: ['fslogix-cloud-cache']
        metadata: { displayName: 'Approved shared-key-exception values' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.Storage/storageAccounts' }
          {
            anyOf: [
              { field: 'Microsoft.Storage/storageAccounts/allowSharedKeyAccess', exists: 'false' }
              { field: 'Microsoft.Storage/storageAccounts/allowSharedKeyAccess', equals: 'true' }
            ]
          }
          { field: 'tags[\'shared-key-exception\']', notIn: '[parameters(\'exceptionValues\')]' }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

var guardrailBuiltIns = [
  { id: 'fc4d8e41-e223-45ea-9bf5-eada37891d87', ref: 'vm-encryption-at-host' }
  { id: 'b2982f36-99f2-4db5-8eff-283140c09693', ref: 'storage-no-public-network' }
  { id: '405c5871-3e91-4644-8a63-58e19d68ff5b', ref: 'keyvault-no-public-network' }
  { id: '48c5f1cb-14ad-4797-8e3b-f78ab3f8d700', ref: 'automation-no-local-auth' }
  { id: '955a914f-bf86-4f0e-acd5-e0766b0efcb6', ref: 'automation-no-public-network' }
]

resource guardrails 'Microsoft.Authorization/policySetDefinitions@2025-01-01' = {
  name: 'platform-guardrails'
  properties: {
    displayName: 'Platform guardrails'
    description: 'Security defaults this platform deploys with (CONVENTIONS.md, Security defaults), checked continuously: no shared keys without an approved exception, no public network access on storage, Key Vault and Automation, encryption at host, no Automation local auth.'
    policyType: 'Custom'
    metadata: { category: 'Security', version: '1.0.0' }
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
      sharedKeyExceptionValues: {
        type: 'Array'
        defaultValue: ['fslogix-cloud-cache']
        metadata: { displayName: 'Approved shared-key-exception values' }
      }
    }
    policyDefinitions: concat(
      [
        {
          policyDefinitionId: sharedKeyPolicy.id
          policyDefinitionReferenceId: 'storage-shared-key-exception'
          parameters: {
            effect: { value: '[parameters(\'effect\')]' }
            exceptionValues: { value: '[parameters(\'sharedKeyExceptionValues\')]' }
          }
        }
      ],
      map(guardrailBuiltIns, p => {
        policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', p.id)
        policyDefinitionReferenceId: p.ref
        parameters: { effect: { value: '[parameters(\'effect\')]' } }
      })
    )
  }
}

// Assigning the regulatory initiative at a management group is what Defender for Cloud lists as
// the NIST SP 800-53 Rev. 5 standard on the Regulatory compliance dashboard.
module nistAssignment 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = if (assignNist) {
  name: '${uniqueString(deployment().name, managementGroupId)}-pa-nist'
  params: {
    name: 'NIST-800-53-R5'
    displayName: 'NIST SP 800-53 Rev. 5'
    description: 'NIST SP 800-53 Rev. 5 regulatory compliance initiative (built-in). Reports policy compliance per control; it is not an assessment of the controls.'
    metadata: { assignedBy: 'Platform governance (az-landing-zone/governance)' }
    policyDefinitionId: nistInitiativeId
    parameters: nistParameters
    identity: 'None'
    managementGroupId: managementGroupId
    location: location
    enforcementMode: enforcementMode
    nonComplianceMessages: [{ message: 'NIST SP 800-53 Rev. 5 policy. See docs/CONTROL-MAPPING.md.' }]
    enableTelemetry: enableTelemetry
  }
}

module guardrailsAssignment 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = {
  name: '${uniqueString(deployment().name, managementGroupId)}-pa-guardrails'
  params: {
    name: 'Platform-Guardrails'
    displayName: 'Platform guardrails'
    description: 'Platform security defaults. Exceptions use documented tags (shared-key-exception) or policy exemptions.'
    metadata: { assignedBy: 'Platform governance (az-landing-zone/governance)' }
    policyDefinitionId: guardrails.id
    parameters: {
      effect: { value: guardrailEffect }
      sharedKeyExceptionValues: { value: sharedKeyExceptionValues }
    }
    identity: 'None'
    managementGroupId: managementGroupId
    location: location
    enforcementMode: enforcementMode
    nonComplianceMessages: [{ message: 'Platform guardrail. See docs/DECISIONS.md (D-032) for exceptions.' }]
    enableTelemetry: enableTelemetry
  }
}

@description('Resource ID of the guardrails initiative.')
output guardrailsInitiativeResourceId string = guardrails.id

@description('Resource ID of the NIST SP 800-53 Rev. 5 assignment, empty when assignNist is false.')
output nistAssignmentResourceId string = assignNist ? nistAssignment!.outputs.resourceId : ''

@description('Resource ID of the guardrails assignment.')
output guardrailsAssignmentResourceId string = guardrailsAssignment.outputs.resourceId
