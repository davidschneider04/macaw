.PHONY: help generate init fmt lint test plan apply show services hidden teardown destroy login check-dashes \
        bootstrap-init bootstrap-plan bootstrap-apply github-settings

# One organization's settings. terraform.tfvars by default; point VARS at a
# file elsewhere (a private config repository, say) to keep them out of this
# checkout. Without either, the example stands in, which is enough for `make
# lint` on a fresh clone but not for anything that talks to AWS.
VARS ?= $(if $(wildcard terraform.tfvars),terraform.tfvars,terraform.tfvars.example)
TF_VARS = -var-file=$(VARS)
export VARS

# The one SSO profile everything uses. Member accounts are reached by assuming
# a role from it, so this is the only login there is.
PROFILE = $(shell grep -hoE '^management_profile *= *"[^"]+"' $(VARS) 2>/dev/null | cut -d'"' -f2)

help:
	@echo "Settings: $(VARS)   (override with VARS=path/to/file.tfvars)"
	@echo ""
	@echo "make login    - aws sso login for the management profile (covers every account)"
	@echo "make init     - terraform init"
	@echo "make plan     - terraform plan, saved to macaw.tfplan"
	@echo "make apply    - apply exactly the saved plan"
	@echo "make show     - print the live customizations for every account"
	@echo "make hidden ACCOUNT=<alias> - list the services that account's console will hide"
	@echo "make services - list every console service id UXC accepts"
	@echo ""
	@echo "CONSOLE GETTING IN THE WAY? Put it back to the AWS defaults:"
	@echo "make teardown                 - reset every account, no Terraform involved"
	@echo "make teardown ACCOUNT=<alias> - reset one account"
	@echo "make destroy                  - the same through Terraform, which also forgets them"
	@echo ""
	@echo "ONE-TIME SETUP, with an admin profile (see README, Least-privilege setup):"
	@echo "make bootstrap-plan / bootstrap-apply - macaw's permission set and member role"
	@echo "make github-settings REPO=owner/repo  - branch rules, Actions off"
	@echo ""
	@echo "make lint     - fmt check, validate, tests and the dash check (what CI would run)"
	@echo "make test     - the SCP rules and the teardown parser, offline"
	@echo "make fmt      - terraform fmt, the fix for a failing 'make lint'"
	@echo "make generate - rewrite accounts.gen.tf from $(VARS) (the targets above do it)"

# Per-account providers and module calls; see scripts/generate.sh. Always
# rerun rather than tracked by timestamp: it takes a second, and VARS can
# change between invocations without any file getting newer.
generate:
	@scripts/generate.sh $(VARS)

login:
	aws sso login --profile $(PROFILE)

init: generate
	terraform init

fmt:
	terraform fmt -recursive

# The init registers the generated module calls, so lint works on a fresh
# clone (or in CI) without a `make init` first. -backend=false leaves any
# configured state alone.
lint: check-dashes test generate
	terraform fmt -check -recursive
	terraform init -backend=false -input=false >/dev/null
	terraform validate
	terraform -chdir=bootstrap init -backend=false -input=false >/dev/null
	terraform -chdir=bootstrap validate
	bash -n scripts/*.sh

# The SCP rules are a pure module, so its tests need no AWS access. The init is
# for Terraform's sake; the module has no providers to download.
#
# The second half checks that the teardown script, which parses the tfvars
# with grep so that it never depends on Terraform, reads the same accounts
# Terraform does. It runs against the example and against $(VARS).
test:
	terraform -chdir=modules/scp-visibility init -backend=false -input=false >/dev/null
	terraform -chdir=modules/scp-visibility test
	@scripts/check-teardown-parse.sh terraform.tfvars.example
	@[ "$(VARS)" = terraform.tfvars.example ] || scripts/check-teardown-parse.sh $(VARS)

# A saved plan, so that `apply` changes exactly what was reviewed and nothing
# that drifted in between. apply does not regenerate, for the same reason.
plan: generate
	terraform plan $(TF_VARS) -out=macaw.tfplan

apply:
	terraform apply macaw.tfplan
	rm -f macaw.tfplan

show: generate
	@scripts/show.sh

# The break-glass. Plain AWS CLI, so it works when Terraform does not; see the
# header of scripts/teardown.sh. ACCOUNT and YES pass through the environment.
teardown:
	@scripts/teardown.sh

# The orderly version: resets every account (UXC has no delete, so destroying
# the resource is a reset) and empties the state, so the next plan starts from
# nothing rather than re-applying. Needs Terraform, and the organization reads,
# to be working.
destroy: generate
	terraform destroy $(TF_VARS)

# The ids modules/scp-visibility/service_map.tf maps IAM prefixes onto. The
# list is global, so the management profile answers for every account.
services:
	@aws uxc list-services --region us-east-1 --profile $(PROFILE) \
	  --query services --output text | tr '\t' '\n'

# What the current configuration would hide, from a fresh plan. Read-only:
# the plan is thrown away, so nothing is applied.
hidden: generate
	@[ -n "$(ACCOUNT)" ] || { echo "Usage: make hidden ACCOUNT=<alias>" >&2; exit 1; }
	@terraform plan $(TF_VARS) -input=false -no-color -out=hidden.tfplan >/dev/null
	@terraform show -json hidden.tfplan \
	  | jq -r '.planned_values.outputs["$(ACCOUNT)"].value.hidden_services[]'
	@rm -f hidden.tfplan

# bootstrap/: the narrow identities macaw runs as. Its own state and its own
# tfvars (bootstrap/terraform.tfvars), applied with an administrator profile,
# once. Same saved-plan discipline as plan/apply.
bootstrap-init:
	terraform -chdir=bootstrap init

bootstrap-plan:
	terraform -chdir=bootstrap plan -out=bootstrap.tfplan

bootstrap-apply:
	terraform -chdir=bootstrap apply bootstrap.tfplan
	rm -f bootstrap/bootstrap.tfplan
	terraform -chdir=bootstrap output -raw next_steps

github-settings:
	@[ -n "$(REPO)" ] || { echo "Usage: make github-settings REPO=owner/repo" >&2; exit 1; }
	scripts/github-settings.sh $(REPO)

# See STYLE.md.
check-dashes:
	@! git ls-files -z | xargs -0 grep -nIP '\x{2014}|\x{2013}'
