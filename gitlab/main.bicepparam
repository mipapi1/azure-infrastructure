using 'main.bicep'

param dbAdminGroupId = '<gitlab-db-admins-group-object-id>'
param dbAdminGroupName = '<gitlab-db-admins-group-name>'
param postgresPassword = readEnvironmentVariable('GITLAB_DB_PASSWORD', '')
