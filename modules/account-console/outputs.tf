output "account_id" {
  value = local.account_id
}

output "is_management_account" {
  description = "SCPs never bind the management account; for it they describe intent, not a limit."
  value       = local.is_management
}

output "scps" {
  description = "Names of the SCPs that were read, by the level they are attached to."
  value = {
    for target, l in data.aws_organizations_policies_for_target.level :
    target => sort([for id in l.ids : data.aws_organizations_policy.scp[id].name])
  }
}

output "visible_regions" {
  value = local.visible_regions
}

output "visible_services" {
  value = local.visible_services
}

output "unmapped_prefixes" {
  description = "IAM prefixes the SCPs allow that match no console service id."
  value       = module.visibility.unmapped_prefixes
}

output "hidden_services" {
  description = "Console service ids this account will not show. Empty when services are unrestricted."
  value       = local.visible_services == null ? [] : sort(setsubtract(data.aws_uxc_services.all.services, local.visible_services))
}

output "summary" {
  description = "Everything above in one object, for the root module's per-account outputs."
  value = {
    scps              = { for target, l in data.aws_organizations_policies_for_target.level : target => sort([for id in l.ids : data.aws_organizations_policy.scp[id].name]) }
    visible_regions   = local.visible_regions
    visible_services  = local.visible_services
    hidden_services   = local.visible_services == null ? [] : sort(setsubtract(data.aws_uxc_services.all.services, local.visible_services))
    unmapped_prefixes = module.visibility.unmapped_prefixes
  }
}
