// Monthly subscription budget that emails as actual spend passes each threshold (percent).
targetScope = 'subscription'
import { envCode, name } from 'naming.bicep'

param env envCode
param workload string

param amount int
param startDate string
param email string
param thresholds int[] = [25, 50, 75]

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: name(env, 'budget', workload, 'monthly')
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: { startDate: startDate }
    notifications: toObject(
      thresholds,
      t => 'actual${t}',
      t => {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: t
        thresholdType: 'Actual'
        contactEmails: [email]
      }
    )
  }
}
