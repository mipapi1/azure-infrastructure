# Decisions

Short records of choices made while building out the platform. Newest last.

## D-001 Keep suffix-style names
Existing hub and image builder resources are named `<workload>-<env>-<region>-<abbr>`. CAF also allows abbreviation-first names, but renaming deployed resources means replacing them. The shared naming module keeps the existing pattern.

## D-002 Containerized toolchain on linux/amd64
The PowerShell base image (needed for PSRule) is published for amd64 only. The tooling image is pinned to `linux/amd64` and runs under emulation on Apple silicon. PSRule's Bicep expansion timeout is raised to 180 s to allow for it.

## D-003 PSRule scans Azure IaC; Checkov scans everything else
Checkov's Bicep parser fails on current syntax (user-defined types, imports, lambdas), and scanning the compiled ARM output (with every AVM module inlined) ran for hours without finishing. Trivy reads the ARM JSON as CloudFormation and finds nothing. PSRule for Azure expands `.bicepparam` files natively and applies the Well-Architected rules, so it's the Azure IaC gate. Checkov covers Kubernetes, Helm, GitHub workflows, Dockerfiles and secrets. `validate.sh arm` is kept for anyone who wants the compiled templates. CKV_DOCKER_2 (HEALTHCHECK) is skipped because the tooling image is a CLI.

## D-004 Image builder: lateral SSH/RDP deny, gallery what-if suppression
Added an outbound deny for TCP 22/3389 to `VirtualNetwork` on the build, ACI and private endpoint NSGs (the ACI subnet keeps an explicit allow to the build subnet). The `what-if-short-circuiting` warning on the gallery role assignment is suppressed: the principal ID is part of the existing assignment name, and changing it would recreate the assignment.

## D-005 Image builder storage stays LRS (PSRule Azure.Storage.UseReplication)
The account holds scripts and installers that the publish tools can recreate. Converting an existing account from LRS to ZRS is a separate migration, not a template change.
