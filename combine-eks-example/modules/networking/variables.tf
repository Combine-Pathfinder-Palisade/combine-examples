variable "vpc_name" {
  description = "The name to give the VPC"
  type        = string
}

variable "availability_zones" {
  description = "The availability zones to create subnets in"
  type        = list(string)
  default     = ["a", "b", "c"]
}

variable "aws_region" {
  description = "The region to deploy the subnets to"
  type        = string
  default     = "us-east-1"
}

variable "additional_cidr_blocks" {
  description = "A list of any additional CIDR blocks to add to the cluster"
  type        = list(string)
  default     = []
}

variable "cidr_block" {
  description = "Private CIDR block, used as VPC primary CIDR association"
  type        = string
  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "Must be a valid IPv4 CIDR block"
  }
}

variable "create_internet_gateway" {
  description = "Create an Internet Gateway for the VPC"
  type        = bool
  default     = true
}

variable "vpc_tags" {
  description = "Tags to add to the VPC"
  type        = map(string)
  default     = {}
}

variable "environment" {
  description = "The environment the network will be added to"
  type        = string
}
