# Conventions

These rules apply to every folder in the repository. When a rule and existing code disagree, the code is refactored to match the next time it changes.

## Layout

```
modules/            shared modules, reusable by any workload
  shared/           naming.bicep, types.bicep (exported types and functions)
  network/          spoke-network, ...
  monitor/          modules for resources without an AVM
  avd/, aks/        workload-specific building blocks that wrap AVM
az-landing-zone/    platform: governance (management groups, policy) and hub
az-image-builder/   golden images (Windows, Linux, STIG)
az-avd/             Azure Virtual Desktop workload
az-aks/             AKS platform workload
az-apps/            applications deployed onto AKS
tooling/            validation image and scripts
```

Each deployable folder has:

```
main.bicep                 composition only: wires modules, no raw resources unless no AVM exists
params/staging.bicepparam  using '../main.bicep'
params/prod.bicepparam
README.md                  purpose, prerequisites, deploy command, parameter table
```

## Modules

1. **AVM first.** Use `br/public:avm/res/...` or `br/public:avm/ptn/...` pinned to an exact version. Check the [AVM index](https://aka.ms/avm/moduleindex/bicep) for the latest version before adding or upgrading a reference. Renovate tracks upgrades.
2. **Local modules follow the AVM interface.** Parameter names `name`, `location`, `tags`, `lock`, `roleAssignments`, `diagnosticSettings`, `managedIdentities`, `privateEndpoints`, `enableTelemetry`, with types imported from `br/public:avm/utl/types/avm-common-types`. That makes a later swap to an AVM a small change.
3. **Every local module records why it exists** in [DECISIONS.md](DECISIONS.md), and names the AVM it would be replaced by.
4. **No thin wrappers.** Compositions call AVM directly. A local module exists only when it adds behaviour, such as a pattern (spoke network) or a missing feature (AVD session host registration).
5. `metadata name` and `metadata description` at the top of every module. `@description` on every parameter and output.

## Parameters and types

- User-defined types instead of `object`/`array`. Shared types live in `modules/shared/types.bicep` and are imported with `import { ... } from`.
- `@secure()` on every secret. Secrets never have defaults and never appear in outputs.
- `.bicepparam` files only, one per environment, always with `using`.
- `environment` is `'staging' | 'prod'` (`environmentType`). Defaults that differ between environments (SKU, redundancy, retention, locks, scale) are derived from it in `main.bicep`, and the parameter files override them when needed.
- No hard-coded locations, subscription IDs, tenant IDs, IP addresses of real networks, or domain names. Example values in parameter files use RFC 1918 ranges and `contoso.example`-style placeholders.

## Naming

`modules/shared/naming.bicep`:

| Function | Pattern | Example |
|---|---|---|
| `resourceName(workload, env, location, abbr)` | `<workload>-<env>-<region>-<abbr>` | `hub-prod-eus-vnet` |
| `compactName(workload, env, location, abbr, suffix, max)` | lower case, no separators, truncated | `avdprodeusstx7k2` |

Abbreviations follow the Cloud Adoption Framework list (`abbreviations` in the same file). The suffix style (abbreviation last) matches the names already deployed by the hub and image builder.

## Tags

Every resource gets the tags in `tagsType`: `environment`, `workload`, and any of `owner`, `costCenter`, `managedBy`. Azure Policy in `az-landing-zone/governance` requires `environment` and `workload` on resource groups and makes resources inherit them.

## Security defaults

- Public network access off unless a parameter turns it on; private endpoints registered in the hub private DNS zones.
- Managed identities and Entra RBAC; no shared keys, local accounts or access policies.
- TLS 1.2 minimum; HTTPS only.
- `lock` is `CanNotDelete` in prod and off in staging (`lockFor()` in `types.bicep`).
- Diagnostic settings on every resource that supports them, sent to the central Log Analytics workspace, plus a DeployIfNotExists policy as a safety net.
- Encryption: platform-managed keys by default, with `customerManagedKey` parameters exposed where the AVM supports them.

## Formatting and validation

- `bicep format` output is the only accepted style (`make format`).
- `bicepconfig.json` sets the important linter rules to `error`. Warnings are allowed only with a `#disable-next-line <rule>` and a comment giving the reason.
- `make validate` must pass before every commit: build, lint, format check, PSRule for Azure, Checkov, Kubernetes manifests.

## Commits

Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `ci:`, `build:`, `style:`), imperative mood, one logical change per commit, scope in parentheses when it helps (`feat(avd): ...`).
