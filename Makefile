# Every target runs inside the tooling image, so the host only needs Docker.
IMAGE           ?= azinfra-tools:local
PLATFORM        ?= linux/amd64
CHECKOV_IMAGE   ?= bridgecrew/checkov:3.3.17
DOCKER_RUN       = docker run --rm --platform $(PLATFORM) -v "$(CURDIR)":/src -w /src
TOOLS            = $(DOCKER_RUN) $(IMAGE)

.DEFAULT_GOAL := help
.PHONY: help tools validate build lint format format-check psrule scan k8s docs smoke

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-13s %s\n", $$1, $$2}'

tools: ## Build the tooling image
	docker build --platform $(PLATFORM) -t $(IMAGE) tooling

validate: build lint format-check psrule scan k8s ## Run every check

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

k8s: ## Render and validate Kubernetes manifests and Helm charts
	$(TOOLS) tooling/validate.sh k8s

docs: ## Regenerate parameter tables in module READMEs
	$(TOOLS) python3 tooling/gen-docs.py

smoke: ## Deploy the sample app to a local kind cluster and smoke test it
	az-apps/tests/smoke.sh
