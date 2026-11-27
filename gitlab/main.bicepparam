using 'main.bicep'

param env = 's' // p: prod, s: staging
param workload = 'mipapi'
param cluster = 'gitlab' // aks/clusters/gitlab.bicepparam

param dbAdminGroupId = '<gitlab-db-admins-group-object-id>'
param dbAdminGroupName = '<gitlab-db-admins-group-name>'
param postgresPassword = readEnvironmentVariable('GITLAB_DB_PASSWORD', '')
