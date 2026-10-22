# Every target runs inside the tooling image, so the host only needs Docker.
IMAGE           ?= azinfra-tools:local
PLATFORM        ?= linux/amd64
CHECKOV_IMAGE   ?= bridgecrew/checkov:3.3.17
DOCKER_RUN       = docker run --rm --platform $(PLATFORM) -v "$(CURDIR)":/src -w /src
TOOLS            = $(DOCKER_RUN) $(IMAGE)

.DEFAULT_GOAL := help
.PHONY: help tools validate build lint format format-check psrule scan k8s docs docs-check smoke

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-13s %s\n", $$1, $$2}'

tools: ## Build the tooling image
	docker build --platform $(PLATFORM) -t $(IMAGE) tooling

validate: build lint format-check psrule scan k8s docs-check ## Run every check

build: ## Compile every Bicep file and parameter file
	$(TOOLS) tooling/validate.sh build

lint: ## Bicep linter (rules in bicepconfig.json)
	$(TOOLS) tooling/validate.sh lint

format: ## Format all Bicep files in place
	$(TOOLS) tooling/validate.sh format-fix

format-check: ## Fail if any Bicep file is not formatted
	$(TOOLS) tooling/validate.sh format

psrule: ## PSRule for Azure (Well-Architected rules) on parameter files
	$(TOOLS) tooling/validate.sh psrule

scan: ## Checkov IaC and secret scan (config in .checkov.yaml)
	$(DOCKER_RUN) $(CHECKOV_IMAGE) --config-file .checkov.yaml --directory /src
	@# Charts require an image digest, so Checkov's own Helm rendering skips them; scan them rendered.
	$(TOOLS) sh -c 'rm -rf out/rendered && mkdir -p out/rendered && for c in az-apps/charts/*/; do helm template smoke "$$c" -n web -f "$$c/values-kind.yaml" > "out/rendered/$$(basename $$c).yaml"; done'
	docker run --rm --platform $(PLATFORM) -v "$(CURDIR)/out/rendered":/scan:ro -w /tmp $(CHECKOV_IMAGE) --framework kubernetes --skip-check CKV_K8S_11 --compact --quiet --directory /scan

k8s: ## Render and validate Kubernetes manifests and Helm charts
	$(TOOLS) tooling/validate.sh k8s

docs: ## Regenerate parameter tables in module READMEs
	$(TOOLS) python3 tooling/gen-docs.py

docs-check: ## Fail if a README parameter table is out of date
	$(TOOLS) python3 tooling/gen-docs.py --check

smoke: ## Deploy the sample app to a local kind cluster and smoke test it
	docker run --rm --platform $(PLATFORM) --user 0 -e SMOKE_KEEP -v /var/run/docker.sock:/var/run/docker.sock -v "$(CURDIR)":/src -w /src $(IMAGE) az-apps/tests/smoke.sh
