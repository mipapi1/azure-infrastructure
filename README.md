# azure-infrastructure

An Azure platform in plain Bicep: a hub network with a firewall, Azure Virtual Desktop, AKS, a sample app and GitLab. Everything runs in one subscription and one region, and each stack finds the others by fixed resource names.

| Folder | Deploys |
|---|---|
| `governance` | Management groups, subscription placement, two baseline policies |
| `hub` | Hub network, Azure Firewall (egress and DNS for every spoke), Bastion, Log Analytics, budget |
| `image-builder` | Compute Gallery and an Image Builder template for the AVD image |
| `avd` | AVD spoke, host pool, desktop, workspace, Entra-joined session hosts |
| `aks` | AKS spoke, private cluster with Entra ID RBAC, private container registry |
| `apps` | Sample web app (Dockerfile and Kubernetes manifest) |
| `gitlab` | PostgreSQL for GitLab, DNS, firewall rules and Helm values |
| `modules` | Small modules shared by the stacks |

## Prerequisites

- Azure CLI (`az bicep` installs on first use)
- Owner on the subscription
- Owner at the tenant root management group, for `governance`
- Permission to create Entra ID security groups

## Deploy

Follow [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

**Don't commit real IDs.** The `.bicepparam` files hold placeholders such as `<alert-email>`. Fill them in locally and keep those changes out of Git.
