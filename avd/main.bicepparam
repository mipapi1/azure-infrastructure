using 'main.bicep'

param userGroupId = '<avd-users-group-object-id>'
param adminGroupId = '<avd-admins-group-object-id>'
param adminPassword = readEnvironmentVariable('AVD_ADMIN_PASSWORD', '')

// FSLogix profiles: 'AzureFiles' (SMB share) or 'BlobCloudCache' (page blobs).
param profileStorageType = 'AzureFiles'

// Session host image. Empty: Marketplace Windows 11 multi-session + Microsoft 365. For the image
// builder image: az sig image-definition show -g rg-image-builder -r gal_images -i win11-avd --query id -o tsv
param imageId = ''
