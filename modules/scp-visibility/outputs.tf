output "visible_regions" {
  description = "Regions to show, or null when no SCP restricts Regions."
  value       = local.visible_regions
}

output "visible_services" {
  description = "Console service ids to show, or null when no SCP restricts services."
  value       = local.visible_services
}

output "unmapped_prefixes" {
  description = "Reachable IAM prefixes that match no console service id. Review when this changes."
  value       = local.unmapped_prefixes
}
