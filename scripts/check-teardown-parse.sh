#!/usr/bin/env bash
# Check that scripts/teardown.sh reads the same accounts from a settings file
# as Terraform does. Teardown parses the file with grep and sed so that it
# never depends on Terraform; this is what keeps that parse honest. Offline.
#
# Usage: scripts/check-teardown-parse.sh <vars-file>
set -euo pipefail

vars=$1
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cp variables.tf "$scratch/"

want=$(
  echo 'jsonencode({ for k, a in var.accounts : k => a.id })' |
    terraform -chdir="$scratch" console -var-file="$(realpath "$vars")" |
    jq -r 'fromjson | to_entries[] | "\(.key) \(.value)"' | sort
)
got=$(VARS=$vars LIST=1 scripts/teardown.sh | sort)

if [ "$want" != "$got" ]; then
  echo "teardown parse of $vars disagrees with Terraform:" >&2
  diff <(echo "$want") <(echo "$got") | sed 's/^/  /' >&2
  exit 1
fi
echo "teardown parse of $vars: $(wc -l <<<"$got") account(s), matches Terraform"
