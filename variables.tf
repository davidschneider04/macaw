# Everything specific to one organization is an input here, set in
# terraform.tfvars (gitignored). The committed code names no account, no
# color and no ID, so the same checkout serves any organization.
#
# scripts/generate.sh also reads this file, alone, to learn the account
# aliases; keep it free of references to anything else in the configuration.

variable "management_account_id" {
  description = <<-EOT
    The organization's management account. Organizations can only be read from
    here, and SCPs never bind it, so it is treated differently: it is reached
    with management_profile directly rather than through member_role_name, and
    its visible services include the ones with trusted access.

    Also the guard on the management provider: credentials that land anywhere
    else fail at plan time.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be exactly 12 digits."
  }
}

variable "management_profile" {
  description = <<-EOT
    AWS CLI profile for the management account. The only credentials used:
    member accounts are reached by assuming member_role_name from it, so one
    login covers every account.

    Use the macaw permission set from bootstrap/, not an administrator: this
    profile is what any code run by `make` gets to act as.
  EOT
  type        = string
}

variable "member_role_name" {
  description = <<-EOT
    Role assumed in each member account.

    The default is the role bootstrap/ deploys to every member account: it can
    only read and write that account's console settings, and trusts only the
    macaw permission set. See README, "Least-privilege setup".

    OrganizationAccountAccessRole works too, with no bootstrap, but it is an
    administrator in every account it exists in. providers.tf narrows each
    session with a session policy, which guards against mistakes in this code
    but not against malicious code, since the caller writes it.
  EOT
  type        = string
  default     = "macaw-console"
}

variable "accounts" {
  description = <<-EOT
    Every account to customize, keyed by a short alias.

    The alias names the account everywhere else: its module (module.<alias>),
    its output, and `make hidden ACCOUNT=<alias>` / `make teardown
    ACCOUNT=<alias>`. Renaming one is a state move, not an edit; see README.

      id                      12-digit account ID. Required.
      color                   none, red, darkBlue, lightBlue, green, yellow,
                              orange, pink, purple or teal. Default none.
      derive_visibility       false leaves Regions and services at the
                              console default and sets only the color.
                              Default true.
      extra_visible_services  Console service ids to show although no SCP
                              allows them. Mostly for the management account,
                              which SCPs do not bind. Default none.
  EOT
  type = map(object({
    id                     = string
    color                  = optional(string, "none")
    derive_visibility      = optional(bool, true)
    extra_visible_services = optional(set(string), [])
  }))

  validation {
    condition     = alltrue([for a in values(var.accounts) : can(regex("^[0-9]{12}$", a.id))])
    error_message = "Every account id must be exactly 12 digits."
  }

  validation {
    condition     = length(distinct([for a in values(var.accounts) : a.id])) == length(var.accounts)
    error_message = "Two aliases share an account id. One account, one alias."
  }

  # Aliases become module and provider names in the generated configuration,
  # and `org` is the management provider's.
  validation {
    condition     = alltrue([for k in keys(var.accounts) : can(regex("^[a-z][a-z0-9_]*$", k)) && k != "org"])
    error_message = "Aliases must be lowercase letters, digits and underscores, start with a letter, and not be \"org\"."
  }

  validation {
    condition = alltrue([
      for a in values(var.accounts) :
      contains(["none", "red", "darkBlue", "lightBlue", "green", "yellow", "orange", "pink", "purple", "teal"], a.color)
    ])
    error_message = "color must be one of none, red, darkBlue, lightBlue, green, yellow, orange, pink, purple, teal."
  }
}
