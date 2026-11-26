using 'main.bicep'

param sshPublicKey = readEnvironmentVariable('JUMPBOX_SSH_PUBLIC_KEY', '')
// true: STIG-hardened gallery image (image-builder). false: plain Marketplace Ubuntu 24.04.
param hardenedImage = true
