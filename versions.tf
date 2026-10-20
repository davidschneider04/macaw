terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_uxc_account_customizations first shipped in 6.39.0. 6.40.0 fixed an
      # inconsistent-result error when visible_regions or visible_services is an
      # explicit empty set, which is the first thing anyone tries when resetting
      # a list -- so that is the floor.
      version = ">= 6.40, < 7.0"
    }
  }

  # State is local for now, and gitignored. That is a deliberate choice, not an
  # oversight: everything this project manages is one settings object per
  # account, readable by account ID, so a lost state file costs one
  # `terraform import` per account and nothing else. See README for moving it
  # to S3 once more than one machine applies this.
}
