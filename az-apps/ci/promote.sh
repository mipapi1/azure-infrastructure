#!/usr/bin/env bash
# Promotes an image digest to an environment through GitOps: sets image.digest
# in az-apps/charts/web-app/values-<env>.yaml on a new branch and opens a pull
# (or merge) request. Flux deploys it once the request is merged.
#
#   promote.sh <staging|prod> <sha256:...>
#
# GitHub: needs GH_TOKEN and the gh CLI. GitLab: needs GITLAB_TOKEN with api
# scope, CI_API_V4_URL, CI_PROJECT_ID and CI_DEFAULT_BRANCH (set by GitLab).
set -euo pipefail

env="${1:?environment}"
digest="${2:?digest}"
case "$env" in staging|prod) ;; *) echo "unknown environment: $env" >&2; exit 2 ;; esac
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "invalid digest: $digest" >&2; exit 2; }

values="az-apps/charts/web-app/values-${env}.yaml"
branch="promote/web-app-${env}-${digest:7:12}"
base="${CI_DEFAULT_BRANCH:-main}"

# Replace only the digest line under image:, keep comments and layout.
sed -i.bak -E "s|^(  digest: )sha256:[0-9a-f]{64}|\1${digest}|" "$values" && rm -f "$values.bak"
if git diff --quiet -- "$values"; then
  echo "$env already runs $digest"
  exit 0
fi

name="${PROMOTE_GIT_NAME:-ci-promotion}"
email="${PROMOTE_GIT_EMAIL:-ci-promotion@users.noreply.example.invalid}"
title="deploy(web-app): promote ${digest:0:19} to ${env}"

git checkout -b "$branch"
git add "$values"
git -c user.name="$name" -c user.email="$email" commit -m "$title"
git push origin "$branch"

body="Sets image.digest for ${env} to ${digest}. The image was built, scanned and signed by the pipeline that opened this request."
if [ -n "${GH_TOKEN:-}" ]; then
  gh pr create --base "$base" --head "$branch" --title "$title" --body "$body"
elif [ -n "${GITLAB_TOKEN:-}" ]; then
  curl -fsS --request POST --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --data-urlencode "source_branch=${branch}" \
    --data-urlencode "target_branch=${base}" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description=${body}" \
    --data "remove_source_branch=true" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests" >/dev/null
else
  echo "pushed $branch; open the request manually" >&2
fi
