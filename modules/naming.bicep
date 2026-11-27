// Resource names: <env>-<type>-<workload>-<component>, e.g. s-rg-mipapi-avd, with the abbreviations
// from https://www.azureperiodictable.com. env is p (prod) or s (staging). Resources that must be
// globally unique add a 6-character suffix from the subscription, so names never clash; those
// that can't have hyphens join the parts directly, e.g. sstmipapiavd<suffix>.

@export()
@description('Environment: p (prod) or s (staging).')
type envCode = 'p' | 's'

@export()
@description('<env>-<type>-<workload>-<component>')
func name(env envCode, type string, workload string, component string) string => '${env}-${type}-${workload}-${component}'

@export()
@description('Globally unique name with hyphens: <env>-<type>-<workload>-<component>-<suffix>.')
func uniqueName(env envCode, type string, workload string, component string, subscriptionId string) string =>
  '${env}-${type}-${workload}-${component}-${take(uniqueString(subscriptionId), 6)}'

@export()
@description('Globally unique name without hyphens (storage, registry): <env><type><workload><component><suffix>.')
func compactName(env envCode, type string, workload string, component string, subscriptionId string) string =>
  toLower('${env}${type}${workload}${replace(component, '-', '')}${take(uniqueString(subscriptionId), 6)}')
