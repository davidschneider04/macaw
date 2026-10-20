terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.40, < 7.0"
      # aws     -- credentials inside the account being customized. UXC writes
      #            and the enabled-Region lookup are account-scoped.
      # aws.org -- the management account, the only place the Organizations
      #            read APIs answer. Pass the same provider twice when the
      #            account being customized is the management account.
      configuration_aliases = [aws.org]
    }
  }
}
