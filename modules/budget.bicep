// Monthly subscription budget that emails at 80% of actual spend.
targetScope = 'subscription'

param amount int
param startDate string
param email string

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: 'budget-monthly'
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: { startDate: startDate }
    notifications: {
      actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: [email]
      }
    }
  }
}
