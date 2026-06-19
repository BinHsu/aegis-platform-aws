# aegis-platform-aws — Makefile
#
# Local dev + CI-driven backbone. Canonical apply pipeline is GH Actions
# (infra-plan.yml on PR + infra-apply.yml on push-to-main + infra-ops.yml
# for one-shots). Makefile targets exist for:
#   - local fmt/validate/lint/sec sanity before push
#   - emergency / dev manual apply (operator override)
#   - DR drill from the operator's machine (if CI is unavailable)
#
# Multi-region orchestration: this Makefile loops over enabled regions in
# regions.auto.tfvars.json (jq filter) and invokes regional/ once per
# region with per-region scalars. State key is `regional/<region>/`-
# scoped → per-region blast-radius isolation.
#
# Per "Host isolation discipline": every dev tool lives in ./bin/.

ROOT           := $(CURDIR)
BIN            := $(ROOT)/bin
TFVARS_JSON     := $(ROOT)/regions.auto.tfvars.json
REGISTRIES_JSON := $(ROOT)/registries.auto.tfvars.json
BACKEND_HCL     := $(ROOT)/backend.hcl

PATH := $(BIN):$(PATH)
export PATH

# Neutral default for committed reference. Override in your own shell —
# `export AWS_PROFILE=<your-profile>` — before running make.
AWS_PROFILE ?= aegis
export AWS_PROFILE

# Non-interactive apply/destroy. Empty by default so `make` prompts for
# confirmation (operator safety). The DR drill sets AUTO_APPROVE=-auto-approve
# to run unattended; CI runs terraform directly, not via these targets.
AUTO_APPROVE ?=

TF_BOOTSTRAP := terraform/envs/bootstrap
TF_PLATFORM  := terraform/envs/platform
TF_REGIONAL  := terraform/envs/regional

# Enabled region list (jq selects .value.enabled = true). Evaluated lazily
# inside recipes — chicken-and-egg: file may not exist on a fresh clone
# until regions.auto.tfvars.json is created.
ACTIVE_REGIONS = $(shell jq -r '.regions | to_entries[] | select(.value.enabled) | .key' $(TFVARS_JSON) 2>/dev/null)

.PHONY: help dev-setup pre-commit-install fmt validate lint sec crossplane-validate \
        bootstrap regenerate-backend platform regional regional-one \
        all destroy-region destroy-platform clean-bin clean-backend

help:
	@echo "Targets:"
	@echo "  dev-setup              Install pinned tools into ./bin/ + wire the pre-commit hook"
	@echo "  pre-commit-install     Point git core.hooksPath at .githooks/ (done by dev-setup too)"
	@echo "  fmt                    terraform fmt -recursive terraform/"
	@echo "  validate               terraform validate in each env (no backend init)"
	@echo "  lint                   tflint --recursive --chdir=terraform/"
	@echo "  sec                    trivy config terraform/ (MEDIUM+)"
	@echo "  crossplane-validate    offline XBucket composition gate (crossplane render + resource validate; WS4 Axis A)"
	@echo "  bootstrap              Apply bootstrap (one-time; LOCAL state; creates remote backend)"
	@echo "  regenerate-backend     Re-emit ./backend.hcl from bootstrap outputs (run after bootstrap)"
	@echo "  platform               Apply platform env (slow lifecycle; survives DR drill)"
	@echo "  regional               Apply regional env for ALL enabled regions (loops)"
	@echo "  regional-one REGION=X  Apply regional env for ONE region X"
	@echo "  all                    bootstrap → platform → regional (full from scratch)"
	@echo "  destroy-region REGION=X  Destroy one region's regional stack (DR drill target)"
	@echo "  destroy-platform       Destroy platform env (post-submission cleanup)"
	@echo "  clean-bin              Remove ./bin/ (project-local tools)"
	@echo "  clean-backend          Remove ./backend.hcl (regenerated from bootstrap)"
	@echo ""
	@echo "Active regions (enabled in regions.auto.tfvars.json): $(ACTIVE_REGIONS)"

dev-setup:
	./scripts/install-tools.sh $(BIN)
	./scripts/install-crossplane.sh $(BIN)
	@$(MAKE) --no-print-directory pre-commit-install

# Wire git to the committed hook directory. `.githooks/pre-commit` then runs
# on every `git commit` (fmt-check + gitleaks staged scan). Project-local —
# no Python pre-commit framework, no host install.
pre-commit-install:
	git config core.hooksPath .githooks
	@chmod +x .githooks/pre-commit
	@echo ">>> git core.hooksPath -> .githooks/ (pre-commit hook active)"

fmt:
	terraform fmt -recursive terraform/

validate:
	@for env in bootstrap platform regional; do \
	  echo ">>> validate $$env"; \
	  ( cd terraform/envs/$$env && terraform init -backend=false >/dev/null && terraform validate ) || exit 1; \
	done

lint:
	$(BIN)/tflint --recursive --chdir=terraform/

sec:
	# trivy (successor to the EOL tfsec, which can't parse TF 1.5 `check`).
	# --tf-exclude-downloaded-modules: scan our code, not third-party module
	# internals (terraform-aws-modules/*) whose deliberate choices (EKS public
	# endpoint, VPC flow logs) are noted in docs/tradeoffs.md. --skip-dirs drops
	# the example k8s manifests bundled inside those modules. Gate on MEDIUM+.
	$(BIN)/trivy config terraform/ --tf-exclude-downloaded-modules --skip-dirs '**/.terraform/**' --severity MEDIUM,HIGH,CRITICAL --exit-code 1

# WS4 Axis A (ADR-22): offline composition gate for the XBucket XRD/Composition.
# Helm-renders the chart, then crossplane resource validate (XRD + provider
# schemas) + composition render (needs Docker; skipped without it). Same gate CI
# runs in infra-plan.yml :: crossplane-validate.
crossplane-validate:
	BIN=$(BIN) ./scripts/crossplane-validate.sh

# ----------------------------------------------------------------------------
# Apply pipeline (local override path; CI is canonical)
# ----------------------------------------------------------------------------

bootstrap:
	cd $(TF_BOOTSTRAP) && terraform init && terraform apply -var-file=$(TFVARS_JSON)
	@$(MAKE) regenerate-backend

regenerate-backend:
	@cd $(TF_BOOTSTRAP) && terraform output -raw backend_hcl > $(BACKEND_HCL)
	@echo ">>> $(BACKEND_HCL) regenerated:"
	@cat $(BACKEND_HCL)

platform: $(BACKEND_HCL)
	cd $(TF_PLATFORM) && \
	  terraform init -reconfigure -backend-config=$(BACKEND_HCL) && \
	  terraform apply -var-file=$(TFVARS_JSON)

# Loop over all enabled regions. Each iteration is independent — different
# state key, different lock, different blast radius.
regional: $(BACKEND_HCL)
	@for r in $(ACTIVE_REGIONS); do \
	  echo ""; \
	  echo "=================================================="; \
	  echo ">>> regional apply: $$r"; \
	  echo "=================================================="; \
	  $(MAKE) --no-print-directory regional-one REGION=$$r || exit 1; \
	done

# Single-region apply (called by `regional` loop, or invoked directly with
# REGION=eu-central-1 to apply just one).
regional-one: $(BACKEND_HCL)
	@test -n "$(REGION)" || (echo "ERROR: REGION=<region> required"; exit 1)
	@bucket=$$(cd $(TF_BOOTSTRAP) && terraform output -raw bucket_name); \
	tfstate_region=$$(cd $(TF_BOOTSTRAP) && terraform output -raw region); \
	platform_region=$$(jq -r '.platform_region' $(TFVARS_JSON)); \
	cidr=$$(jq -r '.regions["$(REGION)"].cidr' $(TFVARS_JSON)); \
	node_instance=$$(jq -r '.regions["$(REGION)"].node_instance' $(TFVARS_JSON)); \
	node_min=$$(jq -r '.regions["$(REGION)"].node_min' $(TFVARS_JSON)); \
	node_max=$$(jq -r '.regions["$(REGION)"].node_max' $(TFVARS_JSON)); \
	cd $(TF_REGIONAL) && \
	  terraform init -reconfigure \
	    -backend-config="bucket=$$bucket" \
	    -backend-config="region=$$tfstate_region" \
	    -backend-config="key=regional/$(REGION)/terraform.tfstate" \
	    -backend-config="encrypt=true" && \
	  TF_VAR_tfstate_bucket=$$bucket \
	  TF_VAR_tfstate_region=$$tfstate_region \
	  TF_VAR_platform_region=$$platform_region \
	  TF_VAR_region=$(REGION) \
	  TF_VAR_vpc_cidr=$$cidr \
	  TF_VAR_node_instance=$$node_instance \
	  TF_VAR_node_min=$$node_min \
	  TF_VAR_node_max=$$node_max \
	  terraform apply -var-file=$(REGISTRIES_JSON) $(AUTO_APPROVE)

all: bootstrap platform regional

# DR drill: destroy ONE region (per-region state key isolates the
# blast). Others (if enabled) and platform env stay alive.
destroy-region: $(BACKEND_HCL)
	@test -n "$(REGION)" || (echo "ERROR: REGION=<region> required"; exit 1)
	# Delete the greeter Ingress first so the ALB controller removes its ALB —
	# that ALB is not in Terraform state and would otherwise orphan its ENIs
	# and stall the VPC destroy (DependencyViolation). See scripts/dr/pre-destroy.sh.
	./scripts/dr/pre-destroy.sh $(REGION)
	@bucket=$$(cd $(TF_BOOTSTRAP) && terraform output -raw bucket_name); \
	tfstate_region=$$(cd $(TF_BOOTSTRAP) && terraform output -raw region); \
	platform_region=$$(jq -r '.platform_region' $(TFVARS_JSON)); \
	cidr=$$(jq -r '.regions["$(REGION)"].cidr' $(TFVARS_JSON)); \
	node_instance=$$(jq -r '.regions["$(REGION)"].node_instance' $(TFVARS_JSON)); \
	node_min=$$(jq -r '.regions["$(REGION)"].node_min' $(TFVARS_JSON)); \
	node_max=$$(jq -r '.regions["$(REGION)"].node_max' $(TFVARS_JSON)); \
	cd $(TF_REGIONAL) && \
	  terraform init -reconfigure \
	    -backend-config="bucket=$$bucket" \
	    -backend-config="region=$$tfstate_region" \
	    -backend-config="key=regional/$(REGION)/terraform.tfstate" \
	    -backend-config="encrypt=true" && \
	  TF_VAR_tfstate_bucket=$$bucket \
	  TF_VAR_tfstate_region=$$tfstate_region \
	  TF_VAR_platform_region=$$platform_region \
	  TF_VAR_region=$(REGION) \
	  TF_VAR_vpc_cidr=$$cidr \
	  TF_VAR_node_instance=$$node_instance \
	  TF_VAR_node_min=$$node_min \
	  TF_VAR_node_max=$$node_max \
	  terraform destroy -var-file=$(REGISTRIES_JSON) $(AUTO_APPROVE)

# Full destroy of platform (post-submission cleanup). bootstrap's bucket
# + lock table have lifecycle prevent_destroy — operator must edit those
# blocks first for a true full destroy.
destroy-platform: $(BACKEND_HCL)
	cd $(TF_PLATFORM) && \
	  terraform init -reconfigure -backend-config=$(BACKEND_HCL) && \
	  terraform destroy -var-file=$(TFVARS_JSON)

# ----------------------------------------------------------------------------
# Housekeeping
# ----------------------------------------------------------------------------

clean-bin:
	rm -rf $(BIN)

clean-backend:
	rm -f $(BACKEND_HCL)

# Materialize backend.hcl from bootstrap state if missing.
$(BACKEND_HCL):
	@if [ ! -f $(TF_BOOTSTRAP)/terraform.tfstate ]; then \
	  echo "ERROR: bootstrap state missing — run 'make bootstrap' first."; \
	  exit 1; \
	fi
	@$(MAKE) regenerate-backend
