variable "cluster_name" {
  description = "Name of the Amazon EKS cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Version of the Amazon EKS cluster"
  type        = string
}

variable "node_subnet_ids" {
  description = "List of subnet IDs for EKS worker nodes"
  type        = list(string)
}

variable "min_size" {
  description = "Minimum number of nodes in the node group"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of nodes in the node group"
  type        = number
  default     = 3
}

variable "desired_size" {
  description = "Desired number of nodes in the node group"
  type        = number
  default     = 2
}

variable "instance_types" {
  description = "List of instance types for the node group"
  type        = list(string)
  default     = ["t3.medium", "t3.large", "t3.xlarge"]
}

variable "node_group_remote_access_key" {
  description = "The EC2 Key name to add to the instances within the node group"
  type        = string
  default     = null
}

variable "iam_role_permissions_boundary_arn" {
  description = "ARN of the IAM role's permission boundary"
  type        = string
}

variable "is_combine_env" {
  description = "Is the environment this cluster is being deployed to within a Combine deployment"
  type        = bool
  default     = true
}

variable "combine_ca_chain_b64" {
  description = "The CA chain used by Combine in base64 format"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to add to taggable resources"
  type        = map(any)
  default     = {}
}
