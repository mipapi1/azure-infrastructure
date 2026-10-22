#!/usr/bin/env bash
# Repository validation. Runs inside the tooling image (see Makefile), or on any
# host with bicep, pwsh and PSRule.Rules.Azure installed.
#
#   validate.sh build      compile every .bicep entry point and .bicepparam file
#   validate.sh lint       bicep lint on every .bicep and .bicepparam file
#   validate.sh format     fail if any .bicep file is not formatted
#   validate.sh format-fix format every .bicep file in place
#   validate.sh psrule     PSRule for Azure against parameter files
#   validate.sh k8s        kubeconform + helm lint for az-apps and az-aks/gitops
#   validate.sh arm        compile each deployment (main.bicep + params) to out/arm for scanners
#   validate.sh all        everything above except format-fix
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
git config --global --add safe.directory "$PWD" >/dev/null 2>&1 || true

bicep_files() { git ls-files -co --exclude-standard '*.bicep' | grep -v '^\.work/'; }
param_files() { git ls-files -co --exclude-standard '*.bicepparam' | grep -v '^\.work/'; }

fail=0
note() { printf '\n== %s\n' "$*"; }

run_build() {
  note "bicep build"
  local f out
  out=$(mktemp -d)
  for f in $(bicep_files); do
    # Only compile files that are entry points (main.bicep) or standalone modules.
    bicep build "$f" --outdir "$out" >/dev/null 2>"$out/err" || { echo "FAIL $f"; cat "$out/err"; fail=1; }
  done
  for f in $(param_files); do
    bicep build-params "$f" --outfile "$out/p.json" >/dev/null 2>"$out/err" || { echo "FAIL $f"; cat "$out/err"; fail=1; }
  done
  rm -rf "$out"
}

run_lint() {
  note "bicep lint"
  local f log warnings=0
  log=$(mktemp)
  for f in $(bicep_files) $(param_files); do
    if ! bicep lint "$f" >"$log" 2>&1; then fail=1; fi
    if [ -s "$log" ]; then
      cat "$log"
      warnings=$((warnings + $(grep -c ' : Warning ' "$log" || true)))
    fi
  done
  rm -f "$log"
  echo "lint warnings: $warnings"
}

run_format() {
  note "bicep format (check)"
  local f
  for f in $(bicep_files); do
    if ! bicep format "$f" --stdout | diff -q - "$f" >/dev/null; then
      echo "not formatted: $f (run: make format)"
      fail=1
    fi
  done
}

run_format_fix() {
  local f
  for f in $(bicep_files); do bicep format "$f"; done
}

run_psrule() {
  note "PSRule for Azure"
  pwsh -NoProfile -Command '
    $ErrorActionPreference = "Stop"
    Import-Module PSRule.Rules.Azure
    $files = git ls-files -co --exclude-standard "*.bicepparam" | Where-Object { $_ -notmatch "^(\.work|az-image-builder/tests)/" }
    $result = Invoke-PSRule -Module PSRule.Rules.Azure -InputPath $files -Option ps-rule.yaml -Outcome Fail, Error -WarningAction SilentlyContinue
    $result | Sort-Object TargetName, RuleName | Format-Table -AutoSize TargetName, RuleName, Outcome -Wrap | Out-String -Width 200
    if ($result) { exit 1 }
  ' || fail=1
}

run_k8s() {
  note "kubernetes manifests"
  local schemas="-schema-location default -schema-location https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  local d chart overlay
  for chart in $(find az-apps/charts -mindepth 1 -maxdepth 1 -type d 2>/dev/null); do
    helm lint --strict "$chart" || fail=1
    for v in "$chart"/values-*.yaml; do
      [ -e "$v" ] || continue
      helm template smoke "$chart" -f "$v" | kubeconform -strict -summary $schemas || fail=1
    done
  done
  for d in az-apps/platform az-aks/gitops; do
    [ -d "$d" ] || continue
    for overlay in $(find "$d" -name kustomization.yaml -exec dirname {} \;); do
      kustomize build "$overlay" | kubeconform -strict -summary -ignore-missing-schemas $schemas || fail=1
    done
  done
}

# Checkov can't parse current Bicep syntax, so scanners read the compiled ARM
# templates instead: one JSON per parameter file, with the parameter values.
run_arm() {
  note "compile deployments to out/arm"
  rm -rf out/arm && mkdir -p out/arm
  local f base tpl
  for f in $(param_files | grep -E '^az-[^/]+/(.+/)?params/'); do
    base="out/arm/$(echo "${f%.bicepparam}" | tr '/' '_')"
    tpl=$(sed -n "s/^using '\(.*\)'/\1/p" "$f" | head -1)
    bicep build "$(dirname "$f")/$tpl" --outfile "$base.json" || fail=1
    bicep build-params "$f" --outfile "$base.parameters.json" || fail=1
  done
}

case "${1:-all}" in
  build) run_build ;;
  lint) run_lint ;;
  format) run_format ;;
  format-fix) run_format_fix ;;
  psrule) run_psrule ;;
  k8s) run_k8s ;;
  arm) run_arm ;;
  all) run_build; run_lint; run_format; run_psrule; run_k8s ;;
  *) echo "unknown target: $1" >&2; exit 2 ;;
esac

exit $fail
