variable "admin_profile" {
  description = <<-EOT
    AWS CLI profile with administrator access to the management account. Used
    only to apply this configuration, once and on the rare change after; day
    to day, macaw runs with the narrow permission set this creates.
  EOT
  type        = string
}

variable "permission_set_name" {
  description = <<-EOT
    Name of the Identity Center permission set macaw runs as. It is also how
    member accounts recognize macaw: their role trusts only sessions of this
    permission set, so renaming it means re-applying, which redeploys the
    member role with the new name in its trust policy.
  EOT
  type        = string
  default     = "MacawConsole"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@-]{1,32}$", var.permission_set_name))
    error_message = "Permission set names are 1-32 characters: letters, digits and +=,.@-"
  }
}

variable "member_role_name" {
  description = <<-EOT
    Name of the role deployed to every member account. Must match
    member_role_name in macaw's own settings, whose default is the same.
  EOT
  type        = string
  default     = "macaw-console"
}

variable "assign_to_users" {
  description = <<-EOT
    Identity Center user names (as they sign in) to give the permission set,
    in the management account.
  EOT
  type        = set(string)
  default     = []
}

variable "assign_to_groups" {
  description = "Identity Center group display names to give the permission set, in the management account."
  type        = set(string)
  default     = []
}

variable "target_ou_ids" {
  description = <<-EOT
    OUs whose accounts get the member role, now and as accounts join. Empty
    means the organization root, so every member account. StackSets never
    deploy to the management account, which needs no member role.
  EOT
  type        = set(string)
  default     = []
}
