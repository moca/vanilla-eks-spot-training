SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# These nine keys ARE the config.env contract; scripts/configure.sh is their only
# writer. Nothing is pinned here; both roots are region-agnostic.
CONFIG_KEYS := REGION STATE_REGION CLUSTER_NAME GPU_COUNT GPU_INSTANCE_TYPES \
               EXPECTED_ACCOUNT NANOCHAT_DIR AWS_PROFILE AZ_COUNT

# `VAR=v` in an included makefile outranks the environment, so a bare include
# would swallow `REGION=x make cluster`. Snapshot, include, restore.
$(foreach k,$(CONFIG_KEYS),$(if $(filter environment,$(origin $(k))),$(eval __env_$(k) := $($(k)))))
-include config.env
$(foreach k,$(CONFIG_KEYS),$(if $(filter undefined,$(origin __env_$(k))),,$(eval $(k) := $(__env_$(k)))))

CLUSTER_NAME      ?= nanochat-demo
TF_FOUNDATION     := terraform/live/foundation
TF_EKS            := terraform/live/eks
PLAN_DIR          := $(CURDIR)/.terraform-plans
PLAN_CONTEXT       = $(if $(EXPECTED_ACCOUNT),$(EXPECTED_ACCOUNT)-)$(REGION)
FOUNDATION_PLAN    = $(PLAN_DIR)/foundation-$(PLAN_CONTEXT).tfplan
CLUSTER_PLAN       = $(PLAN_DIR)/cluster-$(PLAN_CONTEXT).tfplan
NANOCHAT_DIR      ?= ../nanochat
NANOCHAT_REPO     := https://github.com/moca/nanochat.git
NANOCHAT_BRANCH   := iteration/observability
NANOCHAT_REF      := a0f52493e96f46071ca35d94b60d95231a5a47ec

# Only when set: the CLI looks up a profile literally named "" and fails on it.
ifneq ($(AWS_PROFILE),)
export AWS_PROFILE
endif

# The foundation root's ONLY region source -- configure.sh writes tfvars under
# eks/ only, so without this `make foundation-plan` stops at an interactive prompt.
ifneq ($(REGION),)
export REGION
export TF_VAR_aws_region ?= $(REGION)
endif
ifneq ($(CLUSTER_NAME),)
export TF_VAR_cluster_name ?= $(CLUSTER_NAME)
endif
# Empty = the variable's own default, every AZ. Never export it empty:
# Terraform cannot parse "" as a number. Set AZ_COUNT=<n> to match an existing VPC.
ifneq ($(AZ_COUNT),)
export TF_VAR_availability_zones_count ?= $(AZ_COUNT)
endif

# The tag is the reproducibility pin -- the job a submodule would have done.
FORK_SHA = $(shell git -C $(NANOCHAT_DIR) rev-parse --short=12 HEAD 2>/dev/null)
# BOTH SHAs: entrypoint.sh and the Dockerfile live in THIS repo, so the fork SHA
# alone leaves the tag unchanged and a node keeps serving the cached layers.
REPO_SHA = $(shell git rev-parse --short=12 HEAD 2>/dev/null)
IMAGE_TAG = $(FORK_SHA)-$(REPO_SHA)
# These read whichever state the directory is init'd to, so they follow REGION
# only after a `make foundation-plan`. Empty = not init'd yet, which `run` catches.
ECR       = $(shell cd $(TF_FOUNDATION) && terraform output -raw ecr_repository_url 2>/dev/null)
BUCKET    = $(shell cd $(TF_FOUNDATION) && terraform output -raw bucket_name 2>/dev/null)
IMAGE     = $(ECR):$(IMAGE_TAG)
# One prefix per run: a fixed one makes the second run "resume" straight to
# COMPLETE, which looks like a pass and proves nothing. Pin RUN_ID to resume on
# purpose. := so `date` runs ONCE -- `?=` re-expands and the workflow and the
# message telling you where to look got different timestamps.
_NOW    := $(shell date -u +%Y%m%d-%H%M%S)
RUN_ID  ?= $(_NOW)
S3_URI    = s3://$(BUCKET)/runs/d12-$(RUN_ID)

# Anything but "dummy" turns W&B on, in both the entrypoint and nanochat.
WANDB_RUN ?= dummy
WANDB_SECRET_ID ?= $(CLUSTER_NAME)/wandb-api-key

.PHONY: help test configure require-config require-cluster-access require-git check-portable \
        foundation foundation-plan foundation-show foundation-apply \
        cluster cluster-plan cluster-show cluster-apply kubeconfig image run inject \
        watch printtag checkpoints timeline grafana argo-ui wandb-key status down \
        down-cluster capacity odcr odcr-cancel clean

help: ## Show this help
	@grep -hE '^[a-z][a-z0-9-]*:.*?## ' $(MAKEFILE_LIST) | sort | awk -F':.*?## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# Without config.env the backend is unconfigured and `terraform init` stops at an
# interactive prompt, which reads as a hang. Name the step instead.
# Also asserts the declared AWS account before Terraform can plan or apply
# billable infrastructure.
require-config:
	@test -n "$(REGION)" && test -f $(TF_EKS)/backend.hcl || { \
	  echo "no config.env (or backend.hcl) in this checkout."; \
	  echo "run: scripts/configure.sh --region <r> --expected-account <12-digit-id> [--gpu-instance-type <t>]"; \
	  exit 1; }
	@printf '%s\n' "$(EXPECTED_ACCOUNT)" | grep -Eq '^[0-9]{12}$$' || { \
	  echo "EXPECTED_ACCOUNT must be the intended 12-digit AWS account ID."; \
	  echo "re-run scripts/configure.sh with --expected-account <12-digit-id>."; \
	  exit 1; }
	@acct=$$(aws sts get-caller-identity --query Account --output text); \
	test "$$acct" = "$(EXPECTED_ACCOUNT)" || { \
	  echo "credentials resolve to account $$acct, config.env expects $(EXPECTED_ACCOUNT)."; \
	  echo "fix AWS_PROFILE; changing the expected ID is not an account switch."; \
	  exit 1; }
	@test "$(TF_VAR_cluster_name)" = "$(CLUSTER_NAME)" || { \
	  echo "TF_VAR_cluster_name=$(TF_VAR_cluster_name) conflicts with CLUSTER_NAME=$(CLUSTER_NAME)."; \
	  echo "unset TF_VAR_cluster_name or make the two values identical."; \
	  exit 1; }

require-cluster-access:
	@test -n "$(TF_VAR_cluster_endpoint_public_access_cidrs)" || { \
	  echo "TF_VAR_cluster_endpoint_public_access_cidrs is required for EKS API access."; \
	  echo "example: export TF_VAR_cluster_endpoint_public_access_cidrs='[\"203.0.113.10/32\"]'"; \
	  exit 1; }
	@command -v jq >/dev/null || { \
	  echo "jq is required to validate EKS API access CIDRs."; \
	  exit 1; \
	}
	@printf '%s\n' '$(TF_VAR_cluster_endpoint_public_access_cidrs)' | \
	  jq -e ' \
	    type == "array" and length > 0 and \
	    all(.[]; \
	      type == "string" and \
	      (try ( \
	        test("^.+/[0-9]+$$") and \
	        (capture("^(?<address>.+)/(?<prefix>[0-9]+)$$") as $$parts | \
	          ($$parts.prefix | tonumber) as $$prefix | \
	          $$prefix > 0 and \
	          (if ($$parts.address | contains(":")) \
	           then $$prefix <= 128 else $$prefix <= 32 end)) \
	      ) catch false) \
	    ) \
	  ' >/dev/null || { \
	    echo "EKS API CIDRs must be a nonempty JSON array of CIDR strings."; \
	    echo "Prefixes must be /1../32 for IPv4 or /1../128 for IPv6; /0 is forbidden."; \
	    echo "Terraform performs authoritative CIDR address validation during plan."; \
	    exit 1; \
	  }

require-git:
	@root=$$(git rev-parse --show-toplevel 2>/dev/null) || { \
	  echo "this command requires a Git checkout; .git is missing."; \
	  echo "release from a clean clone, not a copied working directory."; \
	  exit 1; \
	}; \
	test "$$root" = "$(CURDIR)" || { \
	  echo "Git root is $$root, expected $(CURDIR)."; \
	  exit 1; \
	}
	@git -C "$(NANOCHAT_DIR)" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { \
	  echo "$(NANOCHAT_DIR) is not a Git checkout."; \
	  echo "clone $(NANOCHAT_REPO) branch $(NANOCHAT_BRANCH)."; \
	  exit 1; \
	}
	@actual=$$(git -C "$(NANOCHAT_DIR)" rev-parse HEAD); \
	test "$$actual" = "$(NANOCHAT_REF)" || { \
	  echo "$(NANOCHAT_DIR) is at $$actual, expected $(NANOCHAT_REF)."; \
	  echo "run: git -C $(NANOCHAT_DIR) fetch origin $(NANOCHAT_BRANCH)"; \
	  echo "then: git -C $(NANOCHAT_DIR) checkout --detach $(NANOCHAT_REF)"; \
	  exit 1; \
	}
	@dirty=$$(git status --porcelain --untracked-files=all); \
	test -z "$$dirty" || { \
	  echo "this repository is not clean; commit or remove these files:"; \
	  printf '%s\n' "$$dirty"; \
	  exit 1; \
	}
	@dirty=$$(git -C "$(NANOCHAT_DIR)" status --porcelain --untracked-files=all); \
	test -z "$$dirty" || { \
	  echo "$(NANOCHAT_DIR) is not clean; commit or remove these files:"; \
	  printf '%s\n' "$$dirty"; \
	  exit 1; \
	}
	@test -n "$(REPO_SHA)" && test -n "$(FORK_SHA)" || { \
	  echo "could not resolve both Git revisions."; \
	  exit 1; \
	}

## --- bring up -------------------------------------------------------------

configure: ## Configure an asserted account+region (ARGS='--region ... --expected-account ...')
	bash scripts/configure.sh $(ARGS)

capacity: ## Report where an ODCR could be opened (read-only, no charge)
	bash scripts/find-capacity.sh

check-portable: ## Deny account/region/host literals in tracked files (no AWS, no cluster)
	@bash scripts/check-portable.sh

test: ## Run local release-safety tests (no AWS or cluster changes)
	@bash tests/configure-account-guard.sh
	@bash tests/make-cluster-access-guard.sh
	@bash tests/make-saved-plan-workflow.sh
	@bash terraform/live/eks/tests/endpoint_cidr_validation_test.sh

## --- the ODCR meter ------------------------------------------------------
# An open-ended (HOURS=0) reservation has no expiry to save you.

odcr: require-config ## Show reserved capacity and what it is costing per day
	@aws ec2 describe-capacity-reservations --region $(REGION) \
	  --filters Name=state,Values=active,pending \
	  --query 'CapacityReservations[].{id:CapacityReservationId,type:InstanceType,az:AvailabilityZone,total:TotalInstanceCount,free:AvailableInstanceCount,ends:EndDate,state:State}' \
	  --output table
	@echo "no rows above = nothing reserved, nothing billing"
	@echo "'ends' empty = UNLIMITED: it bills until you run 'make odcr-cancel'"

odcr-cancel: require-config ## Cancel every reservation tagged for this cluster - stops the meter
	@ids=$$(aws ec2 describe-capacity-reservations --region $(REGION) \
	    --filters Name=state,Values=active,pending Name=tag:project,Values=$(CLUSTER_NAME) \
	    --query 'CapacityReservations[].CapacityReservationId' --output text); \
	if [ -z "$$ids" ]; then echo "nothing to cancel"; exit 0; fi; \
	for id in $$ids; do \
	  echo "cancelling $$id"; \
	  aws ec2 cancel-capacity-reservation --region $(REGION) --capacity-reservation-id $$id >/dev/null; \
	done; \
	echo "done. Running instances are NOT terminated - they revert to plain On-Demand."

# Two flags: backend.hcl is per-checkout, the key is per-root AND per-region.
# State keyed BY REGION, because both roots are region-scoped -- a shared key
# turns "change the region" into an unreviewed destroy-and-rebuild inside one
# apply. Each region gets its own state, so a switch builds rather than moves.
TF_INIT = terraform init -input=false -reconfigure -backend-config=backend.hcl

foundation: foundation-plan ## Compatibility alias: save a foundation plan for review

foundation-plan: require-config ## Save an exact foundation plan artifact for review
	@mkdir -p "$(PLAN_DIR)" && chmod 700 "$(PLAN_DIR)"
	@rm -f "$(FOUNDATION_PLAN)"
	cd $(TF_FOUNDATION) && $(TF_INIT) \
	  -backend-config="key=foundation-$(REGION)/terraform.tfstate" && \
	  terraform plan -input=false -lock-timeout=10m -out="$(FOUNDATION_PLAN)"
	@chmod 600 "$(FOUNDATION_PLAN)"
	@echo "saved exact plan: $(FOUNDATION_PLAN)"
	@echo "review it:        make foundation-show"
	@echo "apply it:         make foundation-apply"

foundation-show: require-config ## Render the saved foundation plan without changing AWS
	@test -f "$(FOUNDATION_PLAN)" || { \
	  echo "no saved foundation plan for account $(EXPECTED_ACCOUNT), region $(REGION)."; \
	  echo "run: make foundation-plan"; \
	  exit 1; \
	}
	cd $(TF_FOUNDATION) && terraform show -no-color "$(FOUNDATION_PLAN)"

foundation-apply: require-config ## Apply the exact saved foundation plan (no replan)
	@test -f "$(FOUNDATION_PLAN)" || { \
	  echo "no saved foundation plan for account $(EXPECTED_ACCOUNT), region $(REGION)."; \
	  echo "run and review: make foundation-plan && make foundation-show"; \
	  exit 1; \
	}
	@echo "applying reviewed plan: $(FOUNDATION_PLAN)"
	cd $(TF_FOUNDATION) && $(TF_INIT) \
	  -backend-config="key=foundation-$(REGION)/terraform.tfstate" && \
	  terraform apply -input=false -lock-timeout=10m "$(FOUNDATION_PLAN)"

cluster: cluster-plan ## Compatibility alias: save a cluster plan for review

cluster-plan: require-config require-cluster-access ## Save an exact EKS/observability plan artifact for review
	@mkdir -p "$(PLAN_DIR)" && chmod 700 "$(PLAN_DIR)"
	@rm -f "$(CLUSTER_PLAN)"
	cd $(TF_EKS) && $(TF_INIT) \
	  -backend-config="key=eks-$(REGION)/terraform.tfstate" && \
	  terraform plan -input=false -lock-timeout=10m -out="$(CLUSTER_PLAN)"
	@chmod 600 "$(CLUSTER_PLAN)"
	@echo "saved exact plan: $(CLUSTER_PLAN)"
	@echo "review it:        make cluster-show"
	@echo "apply it:         make cluster-apply"

cluster-show: require-config ## Render the saved cluster plan without changing AWS
	@test -f "$(CLUSTER_PLAN)" || { \
	  echo "no saved cluster plan for account $(EXPECTED_ACCOUNT), region $(REGION)."; \
	  echo "run: make cluster-plan"; \
	  exit 1; \
	}
	cd $(TF_EKS) && terraform show -no-color "$(CLUSTER_PLAN)"

cluster-apply: require-config require-cluster-access ## Apply the exact saved cluster plan (no replan)
	@test -f "$(CLUSTER_PLAN)" || { \
	  echo "no saved cluster plan for account $(EXPECTED_ACCOUNT), region $(REGION)."; \
	  echo "run and review: make cluster-plan && make cluster-show"; \
	  exit 1; \
	}
	@echo "applying reviewed plan: $(CLUSTER_PLAN)"
	cd $(TF_EKS) && $(TF_INIT) \
	  -backend-config="key=eks-$(REGION)/terraform.tfstate" && \
	  terraform apply -input=false -lock-timeout=10m "$(CLUSTER_PLAN)"

kubeconfig: require-config ## Point kubectl at the cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER_NAME)

image: require-config require-git ## Build and push the training image, tagged with both repository SHAs
	@# Same guard `run` has on BUCKET. ECR comes from $(shell terraform output), and
	@# make 3.81 does not pass exported vars to $(shell) -- so with AWS_PROFILE set
	@# only in config.env it resolves EMPTY, and `docker login` with no registry
	@# argument silently targets Docker Hub. Export AWS_PROFILE, or run `make
	@# foundation-apply` if the root is not init'd for this region.
	@test -n "$(ECR)" || { echo "ECR url is empty -- foundation not applied/init'd for $(REGION), or AWS_PROFILE is not in the ENVIRONMENT (config.env alone is not enough here)"; exit 1; }
	@echo "building $(IMAGE)"
	aws ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin $(firstword $(subst /, ,$(ECR)))
	docker build --platform linux/amd64 -f docker/Dockerfile --build-context nanochat=$(NANOCHAT_DIR) -t $(IMAGE) .
	docker push $(IMAGE)

wandb-key: ## Store the W&B API key in Secrets Manager (reads it from stdin)
	bash scripts/set-wandb-key.sh

## --- run the demo ---------------------------------------------------------

run: require-config require-git ## Submit the base_train DAG (uses kubectl; no argo CLI needed)
	@test -n "$(BUCKET)" || { echo "foundation not applied yet"; exit 1; }
	@# The tag includes THIS repo's SHA, so every commit changes it. Without the
	@# guard you find out via a 10-minute ImagePullBackOff.
	@aws ecr describe-images --region $(REGION) --repository-name $(CLUSTER_NAME) \
	   --image-ids imageTag=$(IMAGE_TAG) >/dev/null 2>&1 \
	  || { echo "image $(IMAGE_TAG) is not in ECR -- run 'make image' first"; exit 1; }
	@sed -e 's|__IMAGE__|$(IMAGE)|' \
	     -e 's|__S3_URI__|$(S3_URI)|' \
	     -e 's|__WANDB_RUN__|$(WANDB_RUN)|' \
	     -e 's|__WANDB_SECRET_ID__|$(WANDB_SECRET_ID)|' \
	  k8s/workflow-base-train.yaml | kubectl create -f -
	@echo "run prefix : $(S3_URI)"
	@echo "wandb      : $(WANDB_RUN)"
	@echo; echo "watch it with:  kubectl get pods -w     |     make argo-ui"

inject: ## Inject a termination into Karpenter for the training node
	bash scripts/inject-termination.sh

watch: ## Tail Karpenter, nodeclaims and pods side by side
	@echo "--- karpenter (interruption path)"; kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter --tail=20
	@echo; echo "--- nodeclaims"; kubectl get nodeclaims
	@echo; echo "--- pods"; kubectl get pods -o wide

# Has a SHELF LIFE: the image-pull row comes from the Workflow object, which
# nothing archives. ARGS='--help' for the rest, ARGS='--check' for the fixture.
timeline: ## Wall-clock and $ per phase, plus GPU-idle % (ARGS='--help')
	@bash scripts/timeline.sh $(ARGS)

checkpoints: ## Show the checkpoint timeline in S3 (how much work was lost)
	aws s3 ls --recursive $(S3_URI)/base_checkpoints/ | sort -k1,2

grafana: ## Port-forward Grafana (admin / nanochat-demo)
	@echo "http://localhost:3000  admin / nanochat-demo"
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

argo-ui: ## Port-forward the Argo Workflows UI
	@echo "http://localhost:2746"
	kubectl -n argo port-forward svc/argo-workflows-server 2746:2746

printtag: require-git ## Print the image tag (both SHAs) - useful in scripts
	@echo $(IMAGE_TAG)

status: require-git ## One-shot summary of everything
	@echo "fork SHA : $(FORK_SHA)"
	@echo "image    : $(IMAGE)"
	@echo "bucket   : $(BUCKET)"
	@echo "s3 uri   : $(S3_URI)"
	@cd $(TF_EKS) && terraform output 2>/dev/null || echo "(cluster not applied)"

## --- tear down ------------------------------------------------------------

down-cluster: require-config ## Plan destruction of the cluster ONLY (keeps checkpoints in S3)
	cd $(TF_EKS) && $(TF_INIT) \
	  -backend-config="key=eks-$(REGION)/terraform.tfstate" && \
	  terraform plan -input=false -destroy -out=destroy.tfplan && \
	  echo "REVIEW THE PLAN ABOVE, then: cd $(TF_EKS) && terraform apply destroy.tfplan"

down: require-config ## Plan destruction of everything including checkpoints - DESTRUCTIVE
	@echo "This destroys the S3 bucket holding your checkpoints."
	cd $(TF_FOUNDATION) && $(TF_INIT) \
	  -backend-config="key=foundation-$(REGION)/terraform.tfstate" && \
	  terraform plan -input=false -destroy -out=destroy.tfplan && \
	  echo "REVIEW THE PLAN ABOVE, then: cd $(TF_FOUNDATION) && terraform apply destroy.tfplan"

# The plans above are left on disk on purpose -- you review them, then apply
# them. This is how they leave once applied. Local files only; state is in S3.
clean: ## Remove local plan files and Terraform's error dumps
	@rm -f "$(PLAN_DIR)"/*.tfplan \
	       $(TF_EKS)/*.tfplan $(TF_FOUNDATION)/*.tfplan \
	       $(TF_EKS)/errored.tfstate $(TF_FOUNDATION)/errored.tfstate
