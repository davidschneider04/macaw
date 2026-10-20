#!/usr/bin/env bash
# The GitHub-side controls, as code. Idempotent: re-run after recreating the
# repository, and again on the day it is made public, when the settings at the
# bottom become available. Run after the first push: the branch rule targets
# the default branch, and an empty repository has none. Usage:
#   scripts/github-settings.sh owner/repo
#   make github-settings REPO=owner/repo
#
# What this does and does not protect. macaw's risk is code being run with its
# credentials. These rules make it harder for anyone with a stolen token to
# put code on the default branch without a visible pull request, and keep
# GitHub from running anything at all. They do not review code for you, and
# nothing here stops a branch being checked out and run locally. The real
# limit is that macaw's credentials can only change console settings; see
# README, "Least-privilege setup". Needs `gh` logged in as a repository admin.
set -euo pipefail
R="${1:?usage: $0 owner/repo}"

# Default branch: changes arrive by pull request (zero approvals, so a solo
# maintainer can still merge, but every change is a reviewable diff with a
# record), history cannot be rewritten, and the branch cannot be deleted. No
# bypass actors, so the rule binds admins too.
ruleset=$(cat <<'JSON'
{
  "name": "protect-default-branch",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } }
  ]
}
JSON
)
id=$(gh api "repos/$R/rulesets" -q '.[] | select(.name == "protect-default-branch") | .id')
if [ -n "$id" ]; then
  gh api -X PUT "repos/$R/rulesets/$id" --input - <<<"$ruleset" >/dev/null
else
  gh api -X POST "repos/$R/rulesets" --input - <<<"$ruleset" >/dev/null
fi
echo "ruleset protect-default-branch: applied"

# Actions off. macaw has no workflows, and the safest workflow is one that
# cannot run: a pull request that adds one gets nowhere, and no runner ever
# holds anything of this repository's. If CI is added later, turn this on
# deliberately and give it no AWS credentials.
gh api -X PUT "repos/$R/actions/permissions" -F enabled=false >/dev/null
echo "actions: disabled"

gh api -X PUT "repos/$R/vulnerability-alerts" >/dev/null
echo "dependabot: alerts on"

gh api -X PATCH "repos/$R" -F has_wiki=false -F has_projects=false -F has_discussions=false >/dev/null
echo "features: wiki, projects, discussions off"

public=$(gh api "repos/$R" -q '.visibility == "public"')
if [ "$public" != true ]; then
  echo "private: skipping the public-only settings; re-run after publishing"
  exit 0
fi

# Public only: GitHub offers these free on public repositories.
gh api -X PATCH "repos/$R" --input - >/dev/null <<'JSON'
{ "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" } } }
JSON
gh api -X PUT "repos/$R/private-vulnerability-reporting" >/dev/null
echo "public: secret scanning, push protection, private vulnerability reporting"
