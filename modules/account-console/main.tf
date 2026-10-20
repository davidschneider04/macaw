# One account's console customizations, with the visible Regions and services
# worked out from the organization rather than written by hand.
#
# Inputs, all read at plan time:
#   - the account's path through the organization (root, OUs, account)
#   - every SCP attached anywhere on that path
#   - the services with trusted access to the organization
#   - the Regions enabled for the account
#   - the service ids UXC accepts
#
# So a change to any of those shows up as a diff on the next plan, and nothing
# changes in the console until that plan is applied.

data "aws_caller_identity" "account" {}

data "aws_organizations_organization" "this" {
  provider = aws.org
}

data "aws_organizations_entity_path" "account" {
  provider  = aws.org
  entity_id = data.aws_caller_identity.account.account_id
}

locals {
  account_id    = data.aws_caller_identity.account.account_id
  is_management = local.account_id == data.aws_organizations_organization.this.master_account_id

  # "o-xxxx/r-xxxx/ou-xxxx-aaaa/<account-id>/" -> ["r-xxxx", "ou-xxxx-aaaa", "<account-id>"]
  # Every one of those can have SCPs attached, and all of them apply.
  path_parts = compact(split("/", data.aws_organizations_entity_path.account.entity_path))
  path       = slice(local.path_parts, 1, length(local.path_parts))
}

data "aws_organizations_policies_for_target" "level" {
  for_each = var.derive_visibility ? toset(local.path) : toset([])
  provider = aws.org

  target_id = each.key
  filter    = "SERVICE_CONTROL_POLICY"
}

data "aws_organizations_policy" "scp" {
  for_each = toset(flatten([for l in data.aws_organizations_policies_for_target.level : l.ids]))
  provider = aws.org

  policy_id = each.key
}

data "aws_regions" "enabled" {}

# The list of console ids is global, so it is read once through the management
# account rather than asking every member account for the same answer. It keeps
# uxc:ListServices out of what a member account has to allow.
data "aws_uxc_services" "all" {
  provider = aws.org
}

module "visibility" {
  source = "../scp-visibility"

  policy_levels = [
    for target, l in data.aws_organizations_policies_for_target.level : {
      target = target
      policies = [
        for id in l.ids : {
          name    = data.aws_organizations_policy.scp[id].name
          content = data.aws_organizations_policy.scp[id].content
        }
      ]
    }
  ]

  console_services           = data.aws_uxc_services.all.services
  enabled_regions            = data.aws_regions.enabled.names
  trusted_service_principals = data.aws_organizations_organization.this.aws_service_access_principals
  include_trusted_services   = local.is_management
  extra_visible_services     = var.extra_visible_services
}

locals {
  visible_regions  = var.derive_visibility ? module.visibility.visible_regions : null
  visible_services = var.derive_visibility ? module.visibility.visible_services : null
}

resource "aws_uxc_account_customizations" "this" {
  account_color    = var.account_color
  visible_regions  = local.visible_regions
  visible_services = local.visible_services

  lifecycle {
    # UXC reads an empty list as "show everything". A restriction that
    # resolves to nothing -- an SCP that allows only Regions this account has
    # not enabled, say -- would otherwise silently undo itself.
    precondition {
      condition     = try(length(local.visible_regions), 1) > 0
      error_message = "The SCPs restrict Regions, but none of the Regions they allow is enabled for this account."
    }
    precondition {
      condition     = try(length(local.visible_services), 1) > 0
      error_message = "The SCPs restrict services, but none of the services they allow has a console. Check service_map in modules/scp-visibility."
    }
  }
}
