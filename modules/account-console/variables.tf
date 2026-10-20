variable "account_color" {
  description = "none, red, darkBlue, lightBlue, green, yellow, orange, pink, purple or teal."
  type        = string
  default     = "none"
}

variable "derive_visibility" {
  description = <<-EOT
    Derive visible Regions and services from the organization's SCPs. False
    leaves both at the console default (everything visible) and sets only the
    color.
  EOT
  type        = bool
  default     = true
}

variable "extra_visible_services" {
  description = "Console service ids to show even though no SCP allows them. See modules/scp-visibility."
  type        = set(string)
  default     = []
}
