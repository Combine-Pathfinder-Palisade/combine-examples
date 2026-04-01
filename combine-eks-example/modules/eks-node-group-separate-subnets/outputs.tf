output "node_group_arn" {
  description = "Amazon Resource Name (ARN) of the EKS Node Group"
  value       = module.managed_node_group.node_group_arn
}

output "node_group_id" {
  description = "EKS node group ID"
  value       = module.managed_node_group.node_group_id
}

output "node_group_role_arn" {
  description = "The Amazon Resource Name (ARN) specifying the IAM role"
  value       = module.managed_node_group.iam_role_arn
}

output "node_group_role_name" {
  description = "The name of the IAM role"
  value       = module.managed_node_group.iam_role_name
}

output "node_group_status" {
  description = "Status of the EKS Node Group"
  value       = module.managed_node_group.node_group_status
}

output "launch_template_arn" {
  description = "The ARN of the launch template"
  value       = module.managed_node_group.launch_template_arn
}

output "launch_template_id" {
  description = "The ID of the launch template"
  value       = module.managed_node_group.launch_template_id
}