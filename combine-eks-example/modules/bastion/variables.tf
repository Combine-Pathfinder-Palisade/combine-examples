
variable "admin_users" {
  description = "Users to add as sudo to the EC2 instance"
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "The environment the EC2 instance is for"
  type        = string
}

variable "instance_type" {
  description = "The type of the EC2 instance"
  type        = string
  default     = "t2.medium"
}

variable "key_name" {
  description = "The ssh key for the EC2 instance"
  type        = string
}

variable "subnet_id" {
  description = "The subnet to place the EC2 instance in"
  type        = string
}

variable "tags" {
  description = "Tags to add to the EC2 instance"
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "The VPC to to place the EC2 Security Group in"
  type        = string
}
