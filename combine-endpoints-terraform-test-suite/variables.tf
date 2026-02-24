
variable "access_key" {
  description = "Access key from Combine CAP API"
  type        = string
  default     = "placeholder-access-key"
}

variable "secret_key" {
  description = "Secret key from Combine CAP API"
  type        = string
  default     = "placeholder-secret-key"
}

variable "custom_ca_bundle" {
  description = "Path to Combine's custom CA certificate"
  type        = string
  default     = "your-path-to-ca-bundle"
}

variable "vpc_id" {
  description = "VPC ID for the ALB target group"
  default     = "placeholder-vpcid"
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}