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
            Microsoft.VirtualMachineImages Microsoft.DesktopVirtualization Microsoft.DBforPostgreSQL; do
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

4. Governance. Edit `governance/main.bicepparam`: `subscriptionId` (`az account show --query id -o tsv`).

   ```bash
   az deployment mg create -m "$(az account show --query tenantId -o tsv)" -l eastus \
     -f governance/main.bicep -p governance/main.bicepparam
   ```

5. Hub. Edit `hub/main.bicepparam`: `alertEmail`. The firewall takes 20 to 40 minutes.

   ```bash
   az group create -n rg-hub -l eastus
   az deployment group create -g rg-hub -f hub/main.bicep -p hub/main.bicepparam
   ```

6. Image Builder. No edits. The image build takes 1 to 2 hours.

   ```bash
   az group create -n rg-image-builder -l eastus
   az deployment group create -g rg-image-builder -f image-builder/main.bicep -p image-builder/main.bicepparam
   az image builder run -g rg-image-builder -n it-win11-avd
   ```

7. AVD. Edit `avd/main.bicepparam`: `userGroupId` (avd-users), `adminGroupId` (avd-admins).

   ```bash
   export AVD_ADMIN_PASSWORD='<session host local admin password>'
   az group create -n rg-avd -l eastus
   az deployment group create -g rg-avd -f avd/main.bicep -p avd/main.bicepparam
   ```

   Sign in at <https://windows.cloud.microsoft> as a member of avd-users.

8. AKS. Edit `aks/main.bicepparam`: `adminGroupId` (aks-admins).

   ```bash
   az group create -n rg-aks -l eastus
   az deployment group create -g rg-aks -f aks/main.bicep -p aks/main.bicepparam
   az aks command invoke -g rg-aks -n aks --command "kubectl get nodes"
   ```

9. App. Edit `apps/web-app.yaml`: `<registry-name>` (`az acr list -g rg-aks --query [0].name -o tsv`).

   ```bash
   az acr build -r <registry-name> -t web-app:1 apps
   az aks command invoke -g rg-aks -n aks --file apps/web-app.yaml --command "kubectl apply -f web-app.yaml"
   ```

10. GitLab. Edit `gitlab/main.bicepparam`: `dbAdminGroupId` and `dbAdminGroupName` (gitlab-db-admins).

    ```bash
    export GITLAB_DB_PASSWORD='<PostgreSQL admin password>'
    az group create -n rg-gitlab -l eastus
    az deployment group create -g rg-gitlab -f gitlab/main.bicep -p gitlab/main.bicepparam
    ```

    Edit `gitlab/values.yaml`: `<postgres-server>` (`az postgres flexible-server list -g rg-gitlab --query [0].name -o tsv`).

    ```bash
    az aks command invoke -g rg-aks -n aks --file gitlab/values.yaml --command "\
      kubectl create namespace gitlab && \
      kubectl -n gitlab create secret generic gitlab-postgres --from-literal=password='$GITLAB_DB_PASSWORD' && \
      helm install gitlab gitlab --repo https://charts.gitlab.io --version 10.4.3 -n gitlab -f values.yaml"
    az aks command invoke -g rg-aks -n aks --command \
      "kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d"
    ```

    From an AVD session, open <http://gitlab.gitlab.internal> and sign in as `root` with that password.

11. Tear down. Delete the workloads before the hub, then remove governance.

    ```bash
    for rg in rg-gitlab rg-aks rg-avd rg-image-builder rg-hub; do az group delete -n "$rg" --yes; done
    az policy assignment delete -n allowed-locations --scope /providers/Microsoft.Management/managementGroups/alz
    az policy assignment delete -n security-benchmark --scope /providers/Microsoft.Management/managementGroups/alz
    az account management-group subscription remove -n alz-landingzones -s "$(az account show --query id -o tsv)"
    for mg in alz-landingzones alz-platform alz; do az account management-group delete -n "$mg"; done
    ```
