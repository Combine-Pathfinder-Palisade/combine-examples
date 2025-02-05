variable "admin_users" {
  description = "Users to add as admins"
  type = list(object({
    username = string
    arn      = string
  }))
}

variable "aws_region" {
  description = "The AWS region the EKS cluster is deployed to"
  type        = string
}

variable "aws_profile" {
  description = "The AWS profile to use to authenticate with AWS"
  type        = string
}

variable "admin_role_arns" {
  description = "ARNS for roles to add as admins"
  type        = list(string)
}

variable "cluster_certificate_authority_data" {
  description = "The EKS Cluster's certificate authority"
  type        = string
}

variable "cluster_endpoint" {
  description = "The EKS Cluster's API endpoint"
  type        = string
}

variable "cluster_name" {
  description = "The name of the EKS Cluster"
  type        = string
}

variable "node_group_role_arns" {
  description = "ARNs of the Node Group Roles in the cluster"
  type        = list(string)
}

variable "use_access_entries" {
  description = "Use EKS Access Entries instead of the aws-auth config map"
  type        = bool
  # Currently assigning policies to EKS Access Entries is broken due to a rewriter
  # issue and until that is fixed this will be defaulting to false.
  default = false
}
