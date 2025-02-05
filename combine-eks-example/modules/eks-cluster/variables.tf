variable "aws_region" {
  description = "Specifies the AWS region where resources will be deployed."
  type        = string
  default     = "us-east-1"
}
variable "cluster_admin_arn" {
  description = "The arn to give cluster admin to for the cluster."
  type        = string
}
variable "combine_ca_chain_b64" {
  description = "The CA chain used by Combine in base64 format."
  type        = string
  default     = ""
}
variable "cluster_name" {
  description = "Name of the Amazon EKS cluster the aws load balancer controller is being deployed to."
  type        = string
}
variable "cluster_security_group_additional_cidr_blocks" {
  description = "Additonal CIDR blocks to allow into the EKS cluster."
  type        = list(string)
  default     = []
}
variable "cluster_version" {
  description = "Verison of the Amazon EKS cluster."
  type        = string
}
variable "iam_role_permissions_boundary_arn" {
  description = "ARN of the IAM role's permission boundary."
  type        = string
}
variable "is_combine_env" {
  description = "Is the environment this cluster is being deployed to within a Combine deployment"
  type        = bool
  default     = true
}
variable "node_group_ami_type" {
  description = "The ami type that will be used to deploy the Amazon EKS cluster's node groups."
  type        = string
  default     = "AL2_x86_64"
}
variable "node_group_remote_access_key" {
  description = "The EC2 Key name to add to the instances within the node group."
  type        = string
  default     = null
}
variable "subnet_ids" {
  description = "List of the Amazon VPC Subnets IDs the cluster will be deployed into."
  type        = list(string)
}
variable "tags" {
  description = "Tags to add to taggable resources"
  type        = map(any)
}
variable "vpc_id" {
  description = "ID of the Amazon VPC the cluster will be deployed into."
  type        = string
}
