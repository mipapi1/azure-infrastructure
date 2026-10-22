# Firewall rule collection group

Adds one rule collection group to an existing firewall policy, typically the hub policy from `az-landing-zone`. The firewall policy AVM module manages all groups of a policy at once, so a workload uses this module to own only its rules. Deploy it at the scope of the policy's resource group.

Groups apply in priority order; leave gaps (for example 1000 for AVD, 1100 for AKS) so new workloads fit between them.

## Parameters

<!-- BEGIN_PARAMS -->
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `firewallPolicyName` | string | yes |  | Name of the existing firewall policy (in this resource group). |
| `name` | string | yes |  | Rule collection group name. |
| `priority` | int | yes |  | Priority, unique within the policy (100-65000). |
| `ruleCollections` | array | yes |  | Rule collections, in the firewall policy schema. |

| Output | Type | Description |
|---|---|---|
| `resourceId` | string | Resource ID of the rule collection group. |
<!-- END_PARAMS -->
