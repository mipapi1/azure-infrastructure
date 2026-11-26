# Deployment

Run every command from the repository root. The examples use `eastus`.

1. Sign in and pick the subscription when prompted.

   ```bash
   az login
   ```

2. Register the resource providers. Registration continues in Azure after the loop returns; wait until the second command prints nothing.

   ```bash
   for p in Microsoft.Management Microsoft.Network Microsoft.Compute Microsoft.Storage \
            Microsoft.OperationalInsights Microsoft.Insights Microsoft.ManagedIdentity \
            Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.ContainerInstance \
            Microsoft.VirtualMachineImages Microsoft.DesktopVirtualization Microsoft.DBforPostgreSQL \
            Microsoft.KeyVault Microsoft.SecurityInsights; do
     az provider register --namespace "$p"
   done
   az provider list --query "[?registrationState=='Registering'].namespace" -o tsv
   ```

3. Create the Entra ID groups and add yourself to them. Each `create` prints the group's object ID; note them for the next steps.

   ```bash
   me=$(az ad signed-in-user show --query id -o tsv)
   for g in aks-admins avd-users avd-admins gitlab-db-admins; do
     az ad group create --display-name "$g" --mail-nickname "$g" --query id -o tsv
     az ad group member add --group "$g" --member-id "$me"
   done
   ```

4. Governance. Edit `governance/main.bicepparam`: `subscriptionId` (`az account show --query id -o tsv`). You need Owner at the tenant root management group. Create the top management group first: Azure checks permissions for the policy deployment at `alz` before the template would create it.

   ```bash
   az account management-group create -n alz --display-name "Azure Landing Zones"
   az deployment mg create -m alz -l eastus -f governance/main.bicep -p governance/main.bicepparam
   ```

5. Hub. Edit `hub/main.bicepparam`: `alertEmail`. The firewall takes 20 to 40 minutes.

   ```bash
   az group create -n rg-hub -l eastus
   az deployment group create -g rg-hub -f hub/main.bicep -p hub/main.bicepparam
   ```

6. Image Builder. Each image has its own param file in `image-builder/images/`: the Marketplace source, apps and STIG. Each one creates its own gallery definition and template (`it-<name>`). `win11-avd` is the AVD image, `ubuntu-2404-stig` the jumpbox image, and `win11-vlc` an example to copy. Set `publisherIds` to your object ID (`az ad signed-in-user show --query id -o tsv`) in the files you use.

   Deploy each image, then publish: `publish.sh` downloads every installer the images use, checks its SHA256 and uploads it to the storage account with the build scripts. Builds download them from there over the private endpoint and check every hash again. Each build takes 1 to 2 hours. Run them one after the other: each build's container needs most of the default 4-core Container Instances quota.

   ```bash
   az group create -n rg-image-builder -l eastus
   for i in win11-avd ubuntu-2404-stig; do
     az deployment group create -g rg-image-builder -n image-$i -f image-builder/main.bicep -p image-builder/images/$i.bicepparam
   done
   ./image-builder/publish.sh
   az image builder run -g rg-image-builder -n it-ubuntu-2404-stig
   az image builder run -g rg-image-builder -n it-win11-avd
   ```

   New image: copy `images/win11-vlc.bicepparam`, change `name`, `source`, `apps` and `stig`, then deploy it, run `publish.sh` and run its template. New app: put an install script in `image-builder/apps/` (copy `install-vscode.ps1` or `.sh`; it gets the installer's local path) and add it to the image's `apps` with its download URL and SHA256.

   Image templates can't be updated. To change an image, run `publish.sh`, delete its template (`az image builder delete -g rg-image-builder -n it-<name>`) and deploy it again. If `publish.sh` reports that `scripts.json` changed, commit it first. If a build fails with `SkuNotAvailable`, deploy with `-p buildVmSize=<size>`, picking a size from `az vm list-skus -l eastus --resource-type virtualMachines --query "[?length(restrictions)==\`0\`].name" -o tsv`.

7. Jumpbox (optional). An Ubuntu VM from the hardened image, reached through Bastion. `az network bastion ssh` needs the hub deployed with `-p bastionSku=Standard`.

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/jumpbox
   export JUMPBOX_SSH_PUBLIC_KEY="$(cat ~/.ssh/jumpbox.pub)"
   az group create -n rg-jumpbox -l eastus
   az deployment group create -g rg-jumpbox -f jumpbox/main.bicep -p jumpbox/main.bicepparam
   az network bastion ssh -g rg-hub -n bas-hub --target-resource-id "$(az vm show -g rg-jumpbox -n vm-jumpbox --query id -o tsv)" \
     --auth-type ssh-key --username azureuser --ssh-key ~/.ssh/jumpbox
   sudo stig-scan
   ```

8. AVD. Edit `avd/main.bicepparam`: `userGroupId` (avd-users), `adminGroupId` (avd-admins), `avdServicePrincipalId` (`az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv`), and the host pool, session host, FSLogix and scaling plan settings. Hosts use the Marketplace Windows 11 multi-session image unless you set `imageId` to the image builder's `win11-avd` image. FSLogix profiles go to an Azure Files share by default; set `profileStorageType = 'BlobCloudCache'` for blob storage instead (use it with a STIG image).

   ```bash
   export AVD_ADMIN_PASSWORD='<session host local admin password>'
   az group create -n rg-avd -l eastus
   az deployment group create -g rg-avd -f avd/main.bicep -p avd/main.bicepparam
   ```

   Sign in at <https://windows.cloud.microsoft> as a member of avd-users. Your profile is saved by FSLogix and follows you to any session host.

9. AKS. Edit `aks/main.bicepparam`: `adminGroupId` (aks-admins).

   ```bash
   az group create -n rg-aks -l eastus
   az deployment group create -g rg-aks -f aks/main.bicep -p aks/main.bicepparam
   az aks command invoke -g rg-aks -n aks-platform --command "kubectl get nodes"
   ```

10. App. Edit `apps/web-app.yaml`: `<registry-name>` (`az acr list -g rg-aks --query [0].name -o tsv`).

   ```bash
   az acr build -r <registry-name> -t web-app:1 apps
   # If that fails with TasksOperationsNotAllowed (free-credit subscriptions block ACR Tasks), build locally:
   #   az acr login -n <registry-name>
   #   docker build --platform linux/amd64 -t <registry-name>.azurecr.io/web-app:1 apps
   #   docker push <registry-name>.azurecr.io/web-app:1
   az aks command invoke -g rg-aks -n aks-platform --file apps/web-app.yaml --command "kubectl apply -f web-app.yaml"
   ```

11. GitLab. Edit `gitlab/main.bicepparam`: `dbAdminGroupId` and `dbAdminGroupName` (gitlab-db-admins). If PostgreSQL fails with `The value of the 'Version' should be in: []`, the subscription can't create servers in this region: add `-p postgresLocation=<region>` (check with `az postgres flexible-server list-skus -l <region>`) and add that region to `allowedLocations` in governance.

    ```bash
    export GITLAB_DB_PASSWORD='<PostgreSQL admin password>'
    az group create -n rg-gitlab -l eastus
    az deployment group create -g rg-gitlab -f gitlab/main.bicep -p gitlab/main.bicepparam
    ```

    Install the chart. The commands fill the placeholders in `gitlab/values.yaml` from the deployment outputs and create three secrets: the PostgreSQL password, the Redis access key, and the object storage settings (account name only: GitLab signs in to blob storage with workload identity).

    ```bash
    out() { az deployment group show -g rg-gitlab -n gitlab --query "properties.outputs.$1.value" -o tsv; }
    storage=$(out objectStorageAccount); redis=$(out redisHost)
    postgres=$(az postgres flexible-server list -g rg-gitlab --query [0].name -o tsv)
    redis_key=$(az redisenterprise database list-keys -g rg-gitlab --cluster-name "${redis%%.*}" --query primaryKey -o tsv)
    dir=$(mktemp -d)
    sed -e "s/<postgres-server>/$postgres/" -e "s/<redis-host>/$redis/" -e "s/<gitlab-client-id>/$(out gitlabClientId)/" \
      gitlab/values.yaml > "$dir/values.yaml"
    cat > "$dir/secrets.yaml" <<EOF
    apiVersion: v1
    kind: Secret
    metadata: { name: gitlab-postgres, namespace: gitlab }
    stringData: { password: '$GITLAB_DB_PASSWORD' }
    ---
    apiVersion: v1
    kind: Secret
    metadata: { name: gitlab-redis, namespace: gitlab }
    stringData: { password: '$redis_key' }
    ---
    apiVersion: v1
    kind: Secret
    metadata: { name: gitlab-object-storage, namespace: gitlab }
    stringData:
      connection: |
        provider: AzureRM
        azure_storage_account_name: $storage
        azure_storage_domain: blob.core.windows.net
      registry: |
        azure_v2:
          accountname: $storage
          container: registry
          credentialstype: default_credentials
          realm: core.windows.net
      backup: |
        azure_storage_account_name: $storage
        azure_storage_domain: blob.core.windows.net
    EOF
    az aks command invoke -g rg-aks -n aks-platform --file "$dir" --command "\
      kubectl create namespace gitlab && kubectl apply -f secrets.yaml && \
      helm install gitlab gitlab --repo https://charts.gitlab.io --version 10.4.3 -n gitlab -f values.yaml"
    rm -rf "$dir"
    az aks command invoke -g rg-aks -n aks-platform --command \
      "kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d"
    ```

    From an AVD session, open <http://gitlab.gitlab.internal> and sign in as `root` with that password.

12. Tear down. Delete the workloads before the hub, then remove governance.

    ```bash
    vault=$(az keyvault list -g rg-hub --query [0].name -o tsv)
    for rg in rg-gitlab rg-aks rg-avd rg-jumpbox rg-image-builder rg-hub; do az group delete -n "$rg" --yes; done
    az keyvault purge -n "$vault"
    az policy assignment delete -n allowed-locations --scope /providers/Microsoft.Management/managementGroups/alz
    az policy assignment delete -n security-benchmark --scope /providers/Microsoft.Management/managementGroups/alz
    az account management-group subscription remove -n alz-landingzones -s "$(az account show --query id -o tsv)"
    for mg in alz-landingzones alz-platform alz; do az account management-group delete -n "$mg"; done
    ```
