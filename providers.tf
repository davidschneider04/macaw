# The management account's provider, and what every generated member-account
# provider shares.
#
# UXC settings are account-scoped: there is no organization-level API, so a
# customization is always written by credentials inside the account it applies
# to. That means one provider per account, and Terraform cannot for_each over
# providers (the argument is reserved for a future version). So the
# per-account providers and module calls are generated from var.accounts by
# scripts/generate.sh into accounts.gen.tf, which the Makefile regenerates
# before every plan.
#
# region is us-east-1 because the UXC API only exists there; the resource
# forces it regardless, and saying so here keeps the providers honest.

locals {
  # A session policy for every member-account provider. The effective
  # permissions of an assumed-role session are the intersection of the role's
  # policies and this, so even an administrator role narrows to exactly what
  # modules/account-console calls in a member account: its own UXC settings,
  # and the list of Regions enabled for it. Organization data is read through
  # aws.org, never through these.
  #
  # With bootstrap/'s macaw-console role this repeats what the role already
  # allows. It earns its place with OrganizationAccountAccessRole, where it
  # stops a bug here from becoming an administrator's mistake. It is no
  # defence against malicious code, which would simply leave it out; the role
  # itself is.
  member_session_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "uxc:GetAccountCustomizations",
        "uxc:UpdateAccountCustomizations",
        "ec2:DescribeRegions",
      ]
      Resource = "*"
    }]
  })

  default_tags = {
    Project   = "macaw"
    ManagedBy = "terraform"
  }
}

# The management account. Every module call's `aws.org`, since only this
# account can read the organization, and the `aws` of the management account's
# own module call when it is in var.accounts.
provider "aws" {
  alias               = "org"
  region              = "us-east-1"
  profile             = var.management_profile
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = local.default_tags
  }
}
