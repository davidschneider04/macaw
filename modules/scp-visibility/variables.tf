variable "policy_levels" {
  description = <<-EOT
    The SCPs that apply to one account, grouped by where they are attached:
    the root, each OU on the way down, and the account itself. Order does not
    matter; grouping does, because an allow-list SCP only limits the level it
    is attached to.
  EOT
  type = list(object({
    target = string
    policies = list(object({
      name    = string
      content = string
    }))
  }))
}

variable "console_services" {
  description = "Every service id UXC accepts, from the aws_uxc_services data source."
  type        = set(string)
}

variable "enabled_regions" {
  description = <<-EOT
    Regions enabled for the account. An SCP can allow an opt-in Region the
    account has never opted into; showing it would only offer a Region that
    cannot be used.
  EOT
  type        = set(string)
}

variable "trusted_service_principals" {
  description = "Service principals with trusted access to the organization."
  type        = set(string)
  default     = []
}

variable "include_trusted_services" {
  description = <<-EOT
    Add the services with trusted access to the visible list, whatever the SCPs
    say.

    True for the management account only. It is where trusted access is
    administered, and SCPs never bind it, so a service the SCPs would hide is
    still usable there. In a member account the SCPs do bind, and a trusted
    service they deny is unreachable, so it stays hidden.
  EOT
  type        = bool
  default     = false
}

variable "extra_visible_services" {
  description = <<-EOT
    Console service ids to show even though no SCP allows them. Only takes
    effect when the SCPs restrict services at all.
  EOT
  type        = set(string)
  default     = []
}
