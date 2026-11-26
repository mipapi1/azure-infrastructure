// Monthly subscription budget that emails as actual spend passes each threshold (percent).
targetScope = 'subscription'

param amount int
param startDate string
param email string
param thresholds int[] = [25, 50, 75]

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: 'budget-monthly'
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
