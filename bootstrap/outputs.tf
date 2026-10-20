output "permission_set" {
  value = aws_ssoadmin_permission_set.macaw.name
}

output "member_role_name" {
  value = var.member_role_name
}

output "deployed_to_ous" {
  value = sort(local.target_ou_ids)
}

output "next_steps" {
  description = "What to change in macaw's settings to start using the narrow identity."
  value       = <<-EOT
    1. Add a CLI profile for the permission set to ~/.aws/config, using the
       same sso_session as your admin profile:

         [profile ${var.permission_set_name}-${local.management_account_id}]
         sso_session    = <your sso-session name>
         sso_account_id = ${local.management_account_id}
         sso_role_name  = ${var.permission_set_name}
         region         = us-east-1

    2. In macaw's terraform.tfvars, set
         management_profile = "${var.permission_set_name}-${local.management_account_id}"
       and remove member_role_name unless it differs from "${var.member_role_name}".

    3. make login && make plan -- expect "No changes".
  EOT
}
