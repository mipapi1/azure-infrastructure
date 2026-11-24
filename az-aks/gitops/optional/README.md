# Optional cluster components

Each directory is off until it's added to a cluster. To turn one on, add a Flux Kustomization
for it to `az-aks/gitops/clusters/<cluster>/` (copy `optional.yaml.example`) and list that file
in the cluster's `kustomization.yaml`. Values come from the `cluster-settings` ConfigMap.

| Directory | What it does | Azure side (az-aks) | Settings |
| --- | --- | --- | --- |
| `image-verification` | Kyverno with an ImageValidatingPolicy that checks cosign signatures on images from the cluster registry. Audit by default (D-022). | `addons.imageVerification: true` (identity with AcrPull) | `IMAGE_VERIFICATION_CLIENT_ID`, `SIGNING_ISSUER`, `SIGNING_SUBJECT_REGEXP`, `IMAGE_VERIFICATION_ACTION` (optional, defaults to `Audit`) |
| `trivy-operator` | Trivy Operator: vulnerability, configuration and exposed-secret reports for running workloads. Images and the vulnerability database come from ghcr.io. | none | none |
| `external-dns` | external-dns writing A records for Services and Ingresses into Azure Private DNS zones. | `addons.externalDnsZoneNames` (identity with Private DNS Zone Contributor) | `EXTERNAL_DNS_CLIENT_ID`, `AZURE_SUBSCRIPTION_ID`, `DNS_ZONE_RESOURCE_GROUP`, `EXTERNAL_DNS_DOMAIN` |
| `actions-runner-controller` | GitHub Actions Runner Controller and one runner scale set on the runner pool, unprivileged. | none (the runner pool from `additionalNodeSubnets`) | `GITHUB_CONFIG_URL`; Key Vault secret `github-arc-app` |

AKS Backup has no GitOps part: `addons.backup` deploys the vault, policy, extension and trusted
access, and `az-aks/scripts/new-backup-instance.sh` creates the backup instance.
