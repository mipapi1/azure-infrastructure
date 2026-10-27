metadata name = 'Governance types'
metadata description = 'Parameter types for the management group hierarchy, policy and privileged access.'

@export()
@description('A PIM-eligible Azure role assignment on one management group of the hierarchy.')
type eligibleRoleAssignmentType = {
  @description('Required. Object ID of the group (recommended) or user that becomes eligible.')
  principalId: string

  @description('Required. Role definition GUID, for example 8e3af657-a8ff-443c-a75c-2fe8c4bcb635 for Owner.')
  roleDefinitionId: string

  @description('Required. Management group short name: root, platform, landingzones, sandbox, decommissioned, connectivity, identity, management, corp or online.')
  managementGroup: (
    | 'root'
    | 'platform'
    | 'landingzones'
    | 'sandbox'
    | 'decommissioned'
    | 'connectivity'
    | 'identity'
    | 'management'
    | 'corp'
    | 'online')

  @description('Optional. Justification recorded with the request.')
  justification: string?

  @description('Optional. Days until the eligibility expires (renew by redeploying with requestType AdminRenew or AdminExtend). Defaults to 365.')
  @minValue(1)
  @maxValue(3650)
  durationDays: int?

  @description('Optional. AdminAssign creates the eligibility (first deployment). PIM rejects AdminAssign for an eligibility that already exists, so later deployments use AdminUpdate (same values), AdminExtend/AdminRenew (new end date) or AdminRemove. Defaults to AdminAssign.')
  requestType: ('AdminAssign' | 'AdminUpdate' | 'AdminExtend' | 'AdminRenew' | 'AdminRemove')?
}

@export()
@description('Regulatory compliance and platform guardrail policies, assigned at the root of the hierarchy.')
type compliancePolicyType = {
  @description('Optional. Deploy the guardrails initiative and the NIST assignment. Defaults to true.')
  enabled: bool?

  @description('Optional. Assign the NIST SP 800-53 Rev. 5 initiative (built-in). Defaults to true.')
  nist: bool?

  @description('Optional. Parameter values for the NIST initiative, in assignment format. Defaults to the initiative defaults (Audit or Disabled).')
  nistParameters: object?

  @description('Optional. Enforcement of both assignments, independent of the baseline enforcementMode. Defaults to DoNotEnforce (report only) in every environment; switch prod to Default after the canary has run clean.')
  enforcementMode: ('Default' | 'DoNotEnforce')?

  @description('Optional. Effect of the guardrail policies. Defaults to Audit.')
  guardrailEffect: ('Audit' | 'Deny' | 'Disabled')?

  @description('Optional. Approved values of the shared-key-exception tag. Defaults to [fslogix-cloud-cache].')
  sharedKeyExceptionValues: string[]?
}
