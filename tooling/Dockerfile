# Validation toolchain for this repository. Everything runs in this image so
# the host only needs Docker.
# The PowerShell base image is published for linux/amd64 only; build and run
# with --platform linux/amd64 (Docker Desktop emulates it on Apple silicon).
FROM --platform=linux/amd64 mcr.microsoft.com/powershell:7.5-ubuntu-24.04

ARG BICEP_VERSION=0.47.16
ARG PSRULE_AZURE_VERSION=1.47.0
ARG KUBECONFORM_VERSION=0.8.0
ARG HELM_VERSION=3.22.0
ARG KUSTOMIZE_VERSION=5.8.1
ARG KIND_VERSION=0.33.0
ARG KUBECTL_VERSION=1.34.12
ARG DOCKER_CLI_VERSION=29.9.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git make python3 \
 && rm -rf /var/lib/apt/lists/*

RUN arch=x64 \
 && curl -fsSL -o /usr/local/bin/bicep \
      "https://github.com/Azure/bicep/releases/download/v${BICEP_VERSION}/bicep-linux-${arch}" \
 && chmod +x /usr/local/bin/bicep

RUN arch=amd64 \
 && curl -fsSL "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-${arch}.tar.gz" \
      | tar -xz -C /usr/local/bin kubeconform \
 && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${arch}.tar.gz" \
      | tar -xz -C /tmp \
 && mv "/tmp/linux-${arch}/helm" /usr/local/bin/helm && rm -rf /tmp/linux-* \
 && curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${arch}.tar.gz" \
      | tar -xz -C /usr/local/bin kustomize

RUN pwsh -NoProfile -Command " \
      Set-PSRepository PSGallery -InstallationPolicy Trusted; \
      Install-Module PSRule.Rules.Azure -RequiredVersion ${PSRULE_AZURE_VERSION} -Scope AllUsers -Force -SkipPublisherCheck; \
      Get-Module -ListAvailable PSRule* | Format-Table Name, Version"

# Local smoke test: kind drives the host Docker engine through its socket.
RUN curl -fsSL -o /usr/local/bin/kind "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-amd64" \
 && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" \
      | tar -xz -C /tmp docker/docker \
 && mv /tmp/docker/docker /usr/local/bin/docker && rm -rf /tmp/docker \
 && chmod +x /usr/local/bin/kind /usr/local/bin/kubectl

ENV PSRULE_AZURE_BICEP_PATH=/usr/local/bin/bicep

RUN useradd --create-home --uid 1000 tools 2>/dev/null || useradd --create-home tools
USER tools
WORKDIR /src
