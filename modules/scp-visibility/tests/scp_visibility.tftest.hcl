# Run with `make test`. No credentials needed: the module makes no API calls.
#
# Lists are compared through jsonencode because a module output is a list and
# a bracketed literal is a tuple, and `==` between the two is false even when
# the elements match.

variables {
  console_services = [
    "cloudwatch", "dynamodb", "ec2", "es", "health-dashboard", "lambda",
    "rds", "route53", "s3", "sagemaker", "settings", "sso", "vpc",
  ]
  enabled_regions = ["eu-west-1", "us-east-1", "us-east-2", "us-west-2"]
}

run "full_access_only_restricts_nothing" {
  command = plan

  variables {
    policy_levels = [
      { target = "r-root", policies = [{ name = "FullAWSAccess", content = jsonencode({
        Version   = "2012-10-17"
        Statement = { Effect = "Allow", Action = "*", Resource = "*" }
      }) }] },
    ]
  }

  assert {
    condition     = output.visible_services == null && output.visible_regions == null
    error_message = "FullAWSAccess alone must leave the console at its defaults."
  }
}

# The common shape of an organization root: FullAWSAccess, a deny-all-except list
# of services, a Region deny that exempts global services, and a conditional
# EC2 guardrail that must hide nothing.
run "deny_allowlist_and_region_deny" {
  command = plan

  variables {
    policy_levels = [
      { target = "r-root", policies = [
        { name = "FullAWSAccess", content = jsonencode({
          Statement = [{ Effect = "Allow", Action = "*", Resource = "*" }]
        }) },
        { name = "ApprovedServicesOnly", content = jsonencode({
          Statement = [{
            Effect = "Deny"
            NotAction = [
              "ec2:*", "s3:*", "logs:*", "aoss:*", "route53domains:*",
              "sts:*", "budgets:ViewBudget", "sagemaker:ListHubContents", "uxc:*",
            ]
            Resource = "*"
          }]
        }) },
        { name = "USRegionsOnly", content = jsonencode({
          Statement = [{
            Effect    = "Deny"
            NotAction = ["iam:*", "route53:*", "sts:*"]
            Resource  = "*"
            Condition = { StringNotEquals = { "aws:RequestedRegion" = ["us-east-1", "us-east-2", "us-west-1"] } }
          }]
        }) },
        { name = "SmallInstancesOnly", content = jsonencode({
          Statement = [{
            Effect    = "Deny"
            Action    = ["ec2:RunInstances"]
            Resource  = ["arn:aws:ec2:*:*:instance/*"]
            Condition = { StringNotEquals = { "ec2:InstanceType" = ["t3.small"] } }
          }]
        }) },
      ] },
      { target = "123456789012", policies = [{ name = "FullAWSAccess", content = jsonencode({
        Statement = [{ Effect = "Allow", Action = "*", Resource = "*" }]
      }) }] },
    ]
  }

  assert {
    # ec2 brings vpc; logs lands on cloudwatch, aoss on es, route53domains on
    # route53, uxc on settings; one sagemaker action is enough. dynamodb,
    # lambda and rds are not on the list.
    condition = jsonencode(output.visible_services) == jsonencode([
      "cloudwatch", "ec2", "es", "route53", "s3", "sagemaker", "settings", "vpc",
    ])
    error_message = "Unexpected services: ${jsonencode(output.visible_services)}"
  }

  assert {
    # us-west-1 is allowed but not enabled; eu-west-1 is enabled but denied.
    condition     = jsonencode(output.visible_regions) == jsonencode(["us-east-1", "us-east-2"])
    error_message = "Unexpected Regions: ${jsonencode(output.visible_regions)}"
  }

  assert {
    condition     = jsonencode(output.unmapped_prefixes) == jsonencode(["budgets", "sts"])
    error_message = "Unexpected unmapped prefixes: ${jsonencode(output.unmapped_prefixes)}"
  }
}

run "whole_service_deny_hides_only_unconditional" {
  command = plan

  variables {
    policy_levels = [
      { target = "r-root", policies = [
        { name = "FullAWSAccess", content = jsonencode({
          Statement = { Effect = "Allow", Action = "*", Resource = "*" }
        }) },
        { name = "NoRDS", content = jsonencode({
          Statement = { Effect = "Deny", Action = "rds:*", Resource = "*" }
        }) },
        { name = "NoEC2", content = jsonencode({
          Statement = { Effect = "Deny", Action = ["ec2:*"], Resource = "*" }
        }) },
        # Somebody (the break-glass role) still gets DynamoDB, so it stays.
        { name = "DynamoBreakGlassOnly", content = jsonencode({
          Statement = {
            Effect    = "Deny", Action = "dynamodb:*", Resource = "*"
            Condition = { ArnNotLike = { "aws:PrincipalArn" = "arn:aws:iam::*:role/break-glass" } }
          }
        }) },
      ] },
    ]
  }

  assert {
    condition = (
      !contains(output.visible_services, "rds") &&
      !contains(output.visible_services, "ec2") &&
      !contains(output.visible_services, "vpc") &&
      contains(output.visible_services, "dynamodb") &&
      contains(output.visible_services, "s3")
    )
    error_message = "Unexpected services: ${jsonencode(output.visible_services)}"
  }

  assert {
    condition     = output.visible_regions == null
    error_message = "No Region rule, so Regions must stay at the default."
  }
}

# Allow-list SCPs: an OU without FullAWSAccess allows only what its own Allow
# statements name, and that limit is intersected with every other level.
run "allowlist_at_ou_level" {
  command = plan

  variables {
    policy_levels = [
      { target = "r-root", policies = [{ name = "FullAWSAccess", content = jsonencode({
        Statement = { Effect = "Allow", Action = "*", Resource = "*" }
      }) }] },
      { target = "ou-abcd-11111111", policies = [{ name = "OUAllow", content = jsonencode({
        Statement = { Effect = "Allow", Action = ["s3:*", "lambda:*", "rds:Describe*"], Resource = "*" }
      }) }] },
      { target = "ou-abcd-22222222", policies = [{ name = "OUAllow2", content = jsonencode({
        Statement = { Effect = "Allow", Action = ["s3:*", "lambda:InvokeFunction", "sso:*"], Resource = "*" }
      }) }] },
    ]
  }

  assert {
    condition     = jsonencode(output.visible_services) == jsonencode(["lambda", "s3"])
    error_message = "Unexpected services: ${jsonencode(output.visible_services)}"
  }
}

run "region_deny_with_principal_exemption_hides_nothing" {
  command = plan

  variables {
    policy_levels = [
      { target = "r-root", policies = [
        { name = "FullAWSAccess", content = jsonencode({
          Statement = { Effect = "Allow", Action = "*", Resource = "*" }
        }) },
        { name = "RegionsExceptAdmins", content = jsonencode({
          Statement = {
            Effect = "Deny", NotAction = ["iam:*"], Resource = "*"
            Condition = {
              StringNotEquals = { "aws:RequestedRegion" = ["us-east-1"] }
              ArnNotLike      = { "aws:PrincipalArn" = "arn:aws:iam::*:role/admin" }
            }
          }
        }) },
      ] },
    ]
  }

  assert {
    condition     = output.visible_regions == null
    error_message = "An admin role can use every Region, so none may be hidden."
  }
}

run "region_globs" {
  command = plan

  variables {
    policy_levels = [
      { target = "r-root", policies = [
        { name = "FullAWSAccess", content = jsonencode({
          Statement = { Effect = "Allow", Action = "*", Resource = "*" }
        }) },
        { name = "USOnly", content = jsonencode({
          Statement = {
            Effect    = "Deny", Action = "*", Resource = "*"
            Condition = { StringNotLike = { "aws:RequestedRegion" = "us-*" } }
          }
        }) },
      ] },
    ]
  }

  assert {
    condition     = jsonencode(output.visible_regions) == jsonencode(["us-east-1", "us-east-2", "us-west-2"])
    error_message = "Unexpected Regions: ${jsonencode(output.visible_regions)}"
  }
}

run "trusted_services_only_in_management_account" {
  command = plan

  variables {
    trusted_service_principals = ["sso.amazonaws.com", "health.amazonaws.com"]
    include_trusted_services   = true
    policy_levels = [
      { target = "r-root", policies = [
        { name = "FullAWSAccess", content = jsonencode({
          Statement = { Effect = "Allow", Action = "*", Resource = "*" }
        }) },
        { name = "S3Only", content = jsonencode({
          Statement = { Effect = "Deny", NotAction = "s3:*", Resource = "*" }
        }) },
      ] },
    ]
  }

  assert {
    condition     = jsonencode(output.visible_services) == jsonencode(["health-dashboard", "s3", "sso"])
    error_message = "Unexpected services: ${jsonencode(output.visible_services)}"
  }
}
