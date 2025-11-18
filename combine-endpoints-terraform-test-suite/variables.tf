
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

variable "subnet_1" {
  description = "First subnet ID"
  default     = "placeholder-subnet-1"
}

variable "subnet_2" {
  description = "Second subnet ID"
  default     = "placeholder-subnet-2"
}

variable "subnet_3" {
  description = "Third subnet ID"
  default     = "placeholder-subnet-3"
}

variable "vpc_id" {
  description = "VPC ID for the ALB target group"
  default     = "placeholder-vpcid"
}

variable "bucket_principal_arn" {
  description = "Principal Id for bucket policy"
  default     = "placeholder-principal-id"
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}