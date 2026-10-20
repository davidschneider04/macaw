terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.40, < 7.0"
    }
  }

  # Local, gitignored state, like the main configuration. Everything here can
  # be imported by name if the state is lost.
}

provider "aws" {
  region  = "us-east-1"
  profile = var.admin_profile

  default_tags {
    tags = {
      Project   = "macaw"
      ManagedBy = "terraform"
    }
  }
}
