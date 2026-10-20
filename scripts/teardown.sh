#!/usr/bin/env bash
# Put every account's console back to the AWS defaults: no color, every Region
# and every service visible. The break-glass for when a customization gets in
# the way.
#
# Deliberately independent of Terraform. `terraform destroy` also resets the
# settings, but it reads the organization, every SCP and every account before it
# does anything, so the failures most likely to make you want this -- an SCP
# change, a provider bug, broken state -- are the ones that would stop it. This
# needs only the AWS CLI, jq, a live `make login`, and the settings file, which
# it reads with grep and sed rather than by evaluating the configuration.
#
# One account failing does not stop the rest; failures are listed at the end.
#
# Usage (from the repository root; `make teardown` does this):
#   scripts/teardown.sh                  every account in the settings file
#   ACCOUNT=<alias> scripts/teardown.sh  one account
#   YES=1 scripts/teardown.sh            skip the confirmation
#   LIST=1 scripts/teardown.sh           print the accounts it would reset, and
#                                        stop; no AWS calls
#   VARS=path/to.tfvars ...              settings file (default terraform.tfvars)
#
# Terraform does not know this ran. The next `make plan` shows every
# customization being applied again; see README, "Turning it off".
set -uo pipefail

vars=${VARS:-terraform.tfvars}
[ -r "$vars" ] || { echo "Cannot read $vars. Run from the repository root, or set VARS." >&2; exit 1; }

# Read without Terraform, deliberately. Top-level settings are one
# `key = "value"` per line. Each account is an innermost { ... } block whose
# alias precedes it and which contains `id = "<12 digits>"`; flattening the
# file onto one line lets a block span as many lines as it likes, and since
# account blocks hold only lists, never braces, "innermost" is exact. `make
# test` checks this reading against Terraform's for the example and the live
# file.
profile=$(grep -oE '^management_profile *= *"[^"]+"' "$vars" | cut -d'"' -f2)
mgmt=$(grep -oE '^management_account_id *= *"[0-9]{12}"' "$vars" | grep -oE '[0-9]{12}')
role=$(grep -oE '^member_role_name *= *"[^"]+"' "$vars" | cut -d'"' -f2)
role=${role:-macaw-console}  # variables.tf's default
accounts=$(
  sed -e 's/#.*$//' -e 's|//.*$||' "$vars" | tr '\n' ' ' |
    grep -oE '[a-z][a-z0-9_]* *= *\{[^{}]*\}' |
    sed -nE 's/^([a-z][a-z0-9_]*) *= *\{(.*[^a-z0-9_])?id *= *"([0-9]{12})".*$/\1 \3/p'
)

if [ -n "${ACCOUNT:-}" ]; then
  accounts=$(awk -v a="$ACCOUNT" '$1 == a' <<<"$accounts")
  [ -n "$accounts" ] || { echo "No account '$ACCOUNT' in $vars." >&2; exit 1; }
fi
if [ "${LIST:-}" = 1 ]; then
  [ -z "$accounts" ] || echo "$accounts"
  exit 0
fi
[ -n "$accounts" ] || { echo "No accounts found in $vars." >&2; exit 1; }
[ -n "$profile" ] || { echo "No management_profile in $vars." >&2; exit 1; }
[ -n "$mgmt" ] || { echo "No management_account_id in $vars." >&2; exit 1; }

# The snap-packaged AWS CLI writes nothing when its stdout is a redirect or a
# pipe it did not open itself; `| cat` gives it one.
awsc() { aws "$@" | cat; }

awsc sts get-caller-identity --profile "$profile" --query Account --output text >/dev/null || {
  echo "Cannot use profile $profile. Run 'make login' and try again." >&2
  exit 1
}

echo "Resetting the console to AWS defaults (no color, all Regions, all services) for:"
awk '{ printf "  %-20s %s\n", $1, $2 }' <<<"$accounts"
if [ "${YES:-}" != 1 ]; then
  read -r -p "Type 'yes' to continue: " answer
  [ "$answer" = yes ] || { echo "Nothing changed."; exit 1; }
fi

# Enough to read and reset the settings, and nothing else. The same shape as
# member_session_policy in providers.tf.
session_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["uxc:GetAccountCustomizations","uxc:UpdateAccountCustomizations"],"Resource":"*"}]}'

# Empty lists, not null, are what reset visibility: the CLI rejects null, and
# leaving the lists out changes nothing. Verified against a live account.
reset='{"accountColor":"none","visibleServices":[],"visibleRegions":[]}'

failed=()
while read -r alias id; do
  printf '%-20s ' "$alias"
  (
    if [ "$id" != "$mgmt" ]; then
      creds=$(awsc sts assume-role --profile "$profile" --output json \
        --role-arn "arn:aws:iam::$id:role/$role" --role-session-name macaw-teardown \
        --policy "$session_policy") || exit 1
      export AWS_ACCESS_KEY_ID=$(jq -r .Credentials.AccessKeyId <<<"$creds")
      export AWS_SECRET_ACCESS_KEY=$(jq -r .Credentials.SecretAccessKey <<<"$creds")
      export AWS_SESSION_TOKEN=$(jq -r .Credentials.SessionToken <<<"$creds")
      unset AWS_PROFILE
      auth=()
    else
      auth=(--profile "$profile")
    fi

    awsc uxc update-account-customizations "${auth[@]}" --region us-east-1 \
      --cli-input-json "$reset" >/dev/null || exit 1

    # Read it back rather than trusting the write.
    now=$(awsc uxc get-account-customizations "${auth[@]}" --region us-east-1 --output json) || exit 1
    jq -e '.accountColor == "none" and (.visibleServices | length) == 0 and (.visibleRegions | length) == 0' \
      <<<"$now" >/dev/null || { echo "still customized: $(jq -c . <<<"$now")"; exit 1; }
  ) && echo "reset" || { echo "FAILED"; failed+=("$alias"); }
done <<<"$accounts"

if [ ${#failed[@]} -gt 0 ]; then
  cat >&2 <<EOF

Not reset: ${failed[*]}
Reset those by hand, signed in to each account:
  color                account menu > Account > Account display settings > None
  Regions and services https://console.aws.amazon.com/settings/home > Edit > All
EOF
  exit 1
fi
echo "Done. Reload any open console tabs."
