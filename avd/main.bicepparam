using 'main.bicep'

param userGroupId = '<avd-users-group-object-id>'
param adminGroupId = '<avd-admins-group-object-id>'
param adminPassword = readEnvironmentVariable('AVD_ADMIN_PASSWORD', '')
