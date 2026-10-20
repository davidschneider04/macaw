# The identities macaw runs as, at the least privilege that does the job.
#
# Without this, macaw runs as an administrator of the management account and
# assumes OrganizationAccountAccessRole, also an administrator, in every member
# account. Anyone whose code gets run that way -- a merged pull request, a
# compromised dependency -- owns the organization. A session policy cannot
# stop that, because the caller writes it and malicious code would leave it
# out. The limit has to be on the identities themselves:
#
#   - A permission set in the management account that can read the
#     organization, read and write UXC settings, list Regions, and assume one
#     role by name. Nothing else.
#   - That role, in every member account, deployed by a StackSet so accounts
#     added later get it automatically. It can read and write that account's
#     UXC settings and list its Regions, and it trusts only sessions of the
#     permission set above.
#
# So the worst that code run as macaw can do is change console settings.

data "aws_caller_identity" "current" {}

data "aws_organizations_organization" "this" {}

data "aws_ssoadmin_instances" "this" {}

locals {
  management_account_id = data.aws_caller_identity.current.account_id
  instance_arn          = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id     = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
  target_ou_ids         = length(var.target_ou_ids) > 0 ? var.target_ou_ids : toset([data.aws_organizations_organization.this.roots[0].id])

  # Identity Center creates one role per permission set per account, at
  # /aws-reserved/sso.amazonaws.com/ (with the Region inserted for instances
  # outside us-east-1), named AWSReservedSSO_<permission set>_<hash>. IAM
  # refuses to create anything else under /aws-reserved/, so this pattern can
  # only ever match sessions of this permission set. The underscore after the
  # name stops MacawConsoleX matching MacawConsole.
  permission_set_role_pattern = "arn:aws:iam::${local.management_account_id}:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_${var.permission_set_name}_*"

  # What a member account lets macaw do: exactly what modules/account-console
  # and scripts/teardown.sh call there.
  member_policy = {
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ConsoleSettings"
      Effect = "Allow"
      Action = [
        "uxc:GetAccountCustomizations",
        "uxc:UpdateAccountCustomizations",
        "ec2:DescribeRegions",
      ]
      Resource = "*"
    }]
  }
}

check "management_account" {
  assert {
    condition     = local.management_account_id == data.aws_organizations_organization.this.master_account_id
    error_message = "admin_profile must be for the organization's management account."
  }
}

# ---- Management account: the permission set -------------------------------

resource "aws_ssoadmin_permission_set" "macaw" {
  name             = var.permission_set_name
  description      = "macaw: read the organization, manage console settings, assume ${var.member_role_name}"
  instance_arn     = local.instance_arn
  session_duration = "PT1H"
}

data "aws_iam_policy_document" "macaw" {
  # Everything the organization data sources read. Read-only by construction:
  # no Organizations write action starts with Describe or List.
  statement {
    sid       = "ReadOrganization"
    actions   = ["organizations:Describe*", "organizations:List*"]
    resources = ["*"]
  }

  # The management account's own console settings, and the list of service
  # ids every account's visibility is checked against.
  statement {
    sid = "ConsoleSettings"
    actions = [
      "uxc:GetAccountCustomizations",
      "uxc:UpdateAccountCustomizations",
      "uxc:ListServices",
      "ec2:DescribeRegions",
    ]
    resources = ["*"]
  }

  # Any account's role of this name, which in practice means the ones the
  # StackSet below deployed. A role of the same name somewhere else is no
  # risk: it would also have to trust this permission set to be assumable.
  statement {
    sid       = "AssumeMemberRole"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::*:role/${var.member_role_name}"]
  }
}

resource "aws_ssoadmin_permission_set_inline_policy" "macaw" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.macaw.arn
  inline_policy      = data.aws_iam_policy_document.macaw.json
}

data "aws_identitystore_user" "assignee" {
  for_each          = var.assign_to_users
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = each.key
    }
  }
}

data "aws_identitystore_group" "assignee" {
  for_each          = var.assign_to_groups
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = each.key
    }
  }
}

resource "aws_ssoadmin_account_assignment" "macaw" {
  for_each = merge(
    { for name, u in data.aws_identitystore_user.assignee : "user:${name}" => { type = "USER", id = u.user_id } },
    { for name, g in data.aws_identitystore_group.assignee : "group:${name}" => { type = "GROUP", id = g.group_id } },
  )

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.macaw.arn
  principal_type     = each.value.type
  principal_id       = each.value.id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.management_account_id

  # The inline policy must exist before anyone can sign in with the set, or
  # the first session has no permissions at all.
  depends_on = [aws_ssoadmin_permission_set_inline_policy.macaw]
}

# ---- Member accounts: the role, by StackSet --------------------------------

# Service-managed, so CloudFormation uses the organization's own service-linked
# roles, and auto-deployment gives the role to every account that joins a
# target OU. Needs StackSets trusted access, which Terraform cannot switch on;
# see README, "Least-privilege setup".
resource "aws_cloudformation_stack_set" "member_role" {
  name             = "macaw-member-role"
  description      = "macaw: the role macaw assumes in each member account to manage console settings"
  permission_model = "SERVICE_MANAGED"
  call_as          = "SELF"
  capabilities     = ["CAPABILITY_NAMED_IAM"]

  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Role macaw assumes to manage this account's console settings. Deployed by the macaw-member-role StackSet in the management account."
    Resources = {
      Role = {
        Type = "AWS::IAM::Role"
        Properties = {
          RoleName           = var.member_role_name
          Description        = "macaw: read and write this account's console settings. Trusts only the ${var.permission_set_name} permission set in the management account."
          MaxSessionDuration = 3600
          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Effect    = "Allow"
              Principal = { AWS = "arn:aws:iam::${local.management_account_id}:root" }
              Action    = "sts:AssumeRole"
              Condition = { ArnLike = { "aws:PrincipalArn" = local.permission_set_role_pattern } }
            }]
          }
          Policies = [{ PolicyName = "console-settings", PolicyDocument = local.member_policy }]
          Tags     = [{ Key = "Project", Value = "macaw" }, { Key = "ManagedBy", Value = "cloudformation-stackset" }]
        }
      }
    }
  })

  lifecycle {
    # AWS fills this in for service-managed StackSets and reports it back,
    # which otherwise shows as a change on every plan.
    ignore_changes = [administration_role_arn]
  }
}

resource "aws_cloudformation_stack_instances" "member_role" {
  stack_set_name = aws_cloudformation_stack_set.member_role.name
  call_as        = "SELF"

  # IAM is global, so one Region is enough. us-east-1 because it is where
  # everything else macaw touches lives, and the Region least likely to be
  # denied by an SCP.
  regions = ["us-east-1"]

  deployment_targets {
    organizational_unit_ids = local.target_ou_ids
  }

  operation_preferences {
    failure_tolerance_percentage = 0
    max_concurrent_percentage    = 100
    region_concurrency_type      = "PARALLEL"
  }
}
