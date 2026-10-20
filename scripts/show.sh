#!/usr/bin/env bash
# Print what the UXC API reports for every account in the settings file,
# reached the same way Terraform reaches them: the management profile directly,
# and a member account through var.member_role_name. Read-only.
#
# Values come from `terraform console`, so this reads the settings exactly as a
# plan would and needs no applied state. Run from the repository root; `make
# show` does, passing VARS.
set -euo pipefail

vars=${VARS:-terraform.tfvars}
tfvar() { echo "$1" | terraform console -var-file="$vars" | tr -d '"'; }

profile=$(tfvar 'var.management_profile')
role=$(tfvar 'var.member_role_name')
mgmt=$(tfvar 'var.management_account_id')
accounts=$(echo 'jsonencode({ for k, a in var.accounts : k => a.id })' | terraform console -var-file="$vars" |
  jq -r 'fromjson | to_entries[] | "\(.key) \(.value)"')

# `| cat` throughout: the snap-packaged AWS CLI writes nothing when its stdout
# is a redirect or a command substitution's pipe it did not open itself.

while read -r alias id; do
  echo "== $alias"
  if [ "$id" = "$mgmt" ]; then
    aws uxc get-account-customizations --region us-east-1 --profile "$profile" --output json | cat
    continue
  fi

  creds=$(aws sts assume-role --profile "$profile" --output json \
    --role-arn "arn:aws:iam::$id:role/$role" --role-session-name macaw-show | cat)
  AWS_ACCESS_KEY_ID=$(jq -r .Credentials.AccessKeyId <<<"$creds") \
  AWS_SECRET_ACCESS_KEY=$(jq -r .Credentials.SecretAccessKey <<<"$creds") \
  AWS_SESSION_TOKEN=$(jq -r .Credentials.SessionToken <<<"$creds") \
    env -u AWS_PROFILE aws uxc get-account-customizations --region us-east-1 --output json | cat
done <<<"$accounts"
