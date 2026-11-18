#!/usr/bin/env bash
# Imports the GitLab Runner images into a registry. registry.gitlab.com isn't a supported ACR
# artifact cache upstream, so the images are imported once per runner version instead.
# Run it again after changing the runner chart version (az-gitlab/gitops/base/runner.yaml).
#
#   import-runner-images.sh <registry-name> [runner-version]    default 19.4.0
set -euo pipefail

registry="${1:?registry name}"
version="${2:-19.4.0}"
images=(
  "gitlab-org/gitlab-runner:alpine-v${version}"
  "gitlab-org/gitlab-runner/gitlab-runner-helper:x86_64-v${version}"
)
for image in "${images[@]}"; do
  echo "import  $image"
  az acr import --name "$registry" --source "registry.gitlab.com/${image}" --image "$image" --force
done
