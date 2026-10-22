#!/usr/bin/env bash
# Smoke test for az-apps on a throwaway kind cluster.
#
#   1. create a kind cluster (Kubernetes version matching AKS)
#   2. apply the staging platform overlay (namespace, PSS restricted, quota, default deny)
#   3. install the web-app chart and wait for the rollout
#   4. check the service answers from the allowed namespace
#   5. check another namespace is blocked by the network policies
#
# Runs inside the tooling image with the Docker socket mounted (make smoke),
# or directly on a host that has docker, kind, kubectl and helm.
set -euo pipefail

cluster="${SMOKE_CLUSTER:-azinfra-smoke}"
node_image="kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d"
curl_image="curlimages/curl:8.23.0@sha256:11e64e28c5f58c8d93ee95fcf22ac055f48b0bc440e0ce7d8013bbb5ad6aa8ac"
chart="az-apps/charts/web-app"

log() { printf '\n== %s\n' "$*"; }

cleanup() {
  if [ "${SMOKE_KEEP:-false}" != "true" ]; then
    kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log "create cluster $cluster"
kind create cluster --name "$cluster" --image "$node_image" --wait 180s

# Inside a container the API server is reachable over the kind network only.
if [ -f /.dockerenv ]; then
  docker network connect kind "$(hostname)" 2>/dev/null || true
  export KUBECONFIG="${TMPDIR:-/tmp}/smoke-kubeconfig"
  kind get kubeconfig --internal --name "$cluster" >"$KUBECONFIG"
fi

log "platform overlay"
kubectl apply -k az-apps/platform/overlays/staging
kubectl create namespace smoke --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace other --dry-run=client -o yaml | kubectl apply -f -

log "install chart"
helm upgrade --install web-app "$chart" -n web -f "$chart/values-kind.yaml" --wait --timeout 5m
kubectl -n web rollout status deployment/web-app --timeout=120s

probe() {
  local ns="$1"
  kubectl -n "$ns" run "probe-$RANDOM" --rm -i --restart=Never --quiet \
    --image="$curl_image" --command -- \
    curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://web-app.web.svc.cluster.local/
}

log "allowed namespace reaches the service"
code="$(probe smoke || true)"
if [ "$code" != "200" ]; then
  echo "expected 200 from namespace smoke, got '$code'" >&2
  kubectl -n web get pods,svc,networkpolicy -o wide >&2
  exit 1
fi
echo "HTTP $code"

log "other namespace is blocked"
if code="$(probe other 2>/dev/null)" && [ "$code" = "200" ]; then
  echo "namespace other reached the service; network policy not enforced" >&2
  exit 1
fi
echo "blocked"

log "restricted pod security is enforced"
if kubectl -n web run privileged --image="$curl_image" --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"privileged","image":"'"$curl_image"'","securityContext":{"privileged":true}}]}}' \
  --dry-run=server >/dev/null 2>&1; then
  echo "privileged pod was admitted in namespace web" >&2
  exit 1
fi
echo "privileged pod rejected"

log "smoke test passed"
