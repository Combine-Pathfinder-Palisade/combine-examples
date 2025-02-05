variable "cluster_name" {
  description = "EKS Cluster Name"
  type        = string
}

variable "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster for the OpenID Connect identity provider"
  type        = string
}

variable "oidc_audience" {
  description = "The audience to be used to authenticate with the OIDC provider"
  type        = string
  default     = "sts.amazonaws.com"
}

variable "tags" {
  description = "Tags to add to the OIDC Provider"
  type        = map(any)
  default     = {}
}
