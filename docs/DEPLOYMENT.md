# Deployment

Run every command from the repository root. The examples use `eastus`.

Names follow `<env>-<type>-<workload>-<component>` (`modules/naming.bicep`), for example `s-rg-mipapi-hub`. Set the same `env` (`p` for prod, `s` for staging) and `workload` in every param file, and in your shell for the commands below:

```bash
env=s workload=mipapi
n() { echo "$env-$1-$workload-$2"; }   # n rg hub -> s-rg-mipapi-hub
```

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
            Microsoft.KeyVault Microsoft.SecurityInsights Microsoft.Cache; do
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
   az group create -n "$(n rg hub)" -l eastus
   az deployment group create -g "$(n rg hub)" -f hub/main.bicep -p hub/main.bicepparam
   ```

6. Image Builder. Each image has its own param file in `image-builder/images/`: the Marketplace source, apps, STIG and build settings. Each one creates its own gallery definition and template (`<env>-it-<workload>-<image>`) in the gallery `<env>gal<workload>`. `win11-avd` is the AVD image, `ubuntu-2404-stig` the jumpbox image, and `win11-vlc` an example to copy. Set `publisherIds` to your object ID (`az ad signed-in-user show --query id -o tsv`) in the files you use.

   Deploy each image, then publish: `publish.sh` downloads every installer the images use, checks its SHA256 and uploads it to the storage account with the build scripts. Builds download them from there over the private endpoint and check every hash again. Each build takes 1 to 2 hours. Run them one after the other: each build's container needs most of the default 4-core Container Instances quota.

   ```bash
   az group create -n "$(n rg images)" -l eastus
   for i in win11-avd ubuntu-2404-stig; do
     az deployment group create -g "$(n rg images)" -n image-$i -f image-builder/main.bicep -p image-builder/images/$i.bicepparam
   done
   ./image-builder/publish.sh
   az image builder run -g "$(n rg images)" -n "$(n it ubuntu-2404-stig)"
   az image builder run -g "$(n rg images)" -n "$(n it win11-avd)"
   ```

   New image: copy `images/win11-vlc.bicepparam`, change `name`, `source`, `apps` and `stig`, then deploy it, run `publish.sh` and run its template. New app: put an install script in `image-builder/apps/` (copy `install-vscode.ps1` or `.sh`; it gets the installer's local path) and add it to the image's `apps` with its download URL and SHA256.

   `buildMode` in each image file: `isolated` runs Image Builder's container in the spoke's `snet-container`, `proxy` runs it in Image Builder's own network with a proxy VM in `snet-build`. Image templates can't be updated. To change an image, run `publish.sh`, delete its template (`az image builder delete -g "$(n rg images)" -n "$(n it <image>)"`) and deploy it again. If `publish.sh` reports that `scripts.json` changed, commit it first. If a build fails with `SkuNotAvailable`, set `buildVmSize` (and `proxyVmSize`) in the image's param file to a size from `az vm list-skus -l eastus --resource-type virtualMachines --query "[?length(restrictions)==\`0\`].name" -o tsv` and deploy again.

7. Jumpbox (optional). An Ubuntu VM from the hardened image, reached through Bastion. `az network bastion ssh` needs the hub deployed with `-p bastionSku=Standard`.

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/jumpbox
   export JUMPBOX_SSH_PUBLIC_KEY="$(cat ~/.ssh/jumpbox.pub)"
   az group create -n "$(n rg jumpbox)" -l eastus
   az deployment group create -g "$(n rg jumpbox)" -f jumpbox/main.bicep -p jumpbox/main.bicepparam
   az network bastion ssh -g "$(n rg hub)" -n "$(n bas hub)" \
     --target-resource-id "$(az vm show -g "$(n rg jumpbox)" -n "$(n vml jumpbox)" --query id -o tsv)" \
     --auth-type ssh-key --username azureuser --ssh-key ~/.ssh/jumpbox
   sudo stig-scan
   ```

8. AVD. Edit `avd/main.bicepparam`: `userGroupId` (avd-users), `adminGroupId` (avd-admins), `avdServicePrincipalId` (`az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv`), and the host pool, session host, FSLogix and scaling plan settings. After deleting session hosts, set a new `sessionHosts.forceNewHost` before deploying again: Entra keeps the deleted hosts' devices, so a reused host name can't join. Hosts use the Marketplace Windows 11 multi-session image unless you set `imageId` to the image builder's `win11-avd` image. FSLogix profiles go to an Azure Files share by default; set `fslogix.storageType = 'BlobCloudCache'` for blob storage instead (use it with a STIG image).

   ```bash
   export AVD_ADMIN_PASSWORD='<session host local admin password>'
   az group create -n "$(n rg avd)" -l eastus
   az deployment group create -g "$(n rg avd)" -f avd/main.bicep -p avd/main.bicepparam
   ```

   Sign in at <https://windows.cloud.microsoft> as a member of avd-users. Your profile is saved by FSLogix and follows you to any session host.

9. AKS. Two clusters, each in its own spoke and resource group, from the same template: `aks/clusters/apps.bicepparam` for applications (with the container registry) and `aks/clusters/gitlab.bicepparam` for GitLab and its CI runners, kept apart because runners run any code that is pushed. Edit `adminGroupId` (aks-admins) in both. On a small subscription you can skip the GitLab cluster and set `cluster = 'apps'` in `gitlab/main.bicepparam` to run GitLab on the apps cluster.

   ```bash
   for c in apps gitlab; do
     az group create -n "$(n rg $c)" -l eastus
     az deployment group create -g "$(n rg $c)" -n aks -f aks/main.bicep -p aks/clusters/$c.bicepparam
     az aks command invoke -g "$(n rg $c)" -n "$(n aks $c)" --command "kubectl get nodes"
   done
   ```

10. App. Edit `apps/web-app.yaml`: `<registry-name>` (`az acr list -g "$(n rg apps)" --query "[0].name" -o tsv`).

    ```bash
    az acr build -r <registry-name> -t web-app:1 apps
    # If that fails with TasksOperationsNotAllowed (free-credit subscriptions block ACR Tasks), build locally:
    #   az acr login -n <registry-name>
    #   docker build --platform linux/amd64 -t <registry-name>.azurecr.io/web-app:1 apps
    #   docker push <registry-name>.azurecr.io/web-app:1
    az aks command invoke -g "$(n rg apps)" -n "$(n aks apps)" --file apps/web-app.yaml --command "kubectl apply -f web-app.yaml"
    ```

11. GitLab. Deploys into the GitLab cluster's resource group and spoke. Edit `gitlab/main.bicepparam`: `dbAdminGroupId` and `dbAdminGroupName` (gitlab-db-admins). If PostgreSQL fails with `The value of the 'Version' should be in: []`, the subscription can't create servers in this region: add `-p postgresLocation=<region>` (check with `az postgres flexible-server list-skus -l <region>`) and add that region to `allowedLocations` in governance.

    ```bash
    export GITLAB_DB_PASSWORD='<PostgreSQL admin password>'
    rg=$(n rg gitlab) aks=$(n aks gitlab)
    az deployment group create -g "$rg" -n gitlab -f gitlab/main.bicep -p gitlab/main.bicepparam
    ```

    Install the chart. The commands fill the placeholders in `gitlab/values.yaml` from the deployment outputs, create GitLab's service account (linked to the GitLab workload identity), and create three secrets: the PostgreSQL password, the Redis access key, and the object storage settings (account name only: GitLab signs in to blob storage with workload identity).

    ```bash
    out() { az deployment group show -g "$rg" -n gitlab --query "properties.outputs.$1.value" -o tsv; }
    storage=$(out objectStorageAccount); redis=$(out redisHost)
    postgres=$(az postgres flexible-server list -g "$rg" --query "[0].name" -o tsv)
    redis_key=$(az redisenterprise database list-keys -g "$rg" --cluster-name "${redis%%.*}" --query primaryKey -o tsv)
    dir=$(mktemp -d)
    sed -e "s/<postgres-server>/$postgres/" -e "s/<redis-host>/$redis/" gitlab/values.yaml > "$dir/values.yaml"
    cat > "$dir/secrets.yaml" <<EOF
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: gitlab
      namespace: gitlab
      annotations: { azure.workload.identity/client-id: $(out gitlabClientId) }
    ---
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
          credentials_type: default_credentials
          realm: core.windows.net
      backup: |
        azure_storage_account_name: $storage
        azure_storage_domain: blob.core.windows.net
    EOF
    (cd "$dir" && az aks command invoke -g "$rg" -n "$aks" --file . --command "\
      kubectl create namespace gitlab && kubectl apply -f secrets.yaml && \
      helm install gitlab gitlab --repo https://charts.gitlab.io --version 10.4.3 -n gitlab -f values.yaml")
    rm -rf "$dir"
    az aks command invoke -g "$rg" -n "$aks" --command \
      "kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d"
    ```

    From an AVD session, open <http://gitlab.gitlab.internal> and sign in as `root` with that password.

12. Tear down. Delete the workloads before the hub, then remove governance.

    ```bash
    vault=$(az keyvault list -g "$(n rg hub)" --query "[0].name" -o tsv)
    for c in gitlab apps avd jumpbox images hub; do az group delete -n "$(n rg $c)" --yes; done
    az keyvault purge -n "$vault"
    az policy assignment delete -n allowed-locations --scope /providers/Microsoft.Management/managementGroups/alz
    az policy assignment delete -n security-benchmark --scope /providers/Microsoft.Management/managementGroups/alz
    az account management-group subscription remove -n alz-landingzones -s "$(az account show --query id -o tsv)"
    for mg in alz-landingzones alz-platform alz; do az account management-group delete -n "$mg"; done
    ```
