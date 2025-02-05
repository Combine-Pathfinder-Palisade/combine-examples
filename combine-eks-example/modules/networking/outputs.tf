output "vpc_id" {
  value       = module.main_vpc.vpc_id
  description = "The ID of the VPC"
}

output "public_subnet_ids" {
  value       = module.main_vpc.public_subnets
  description = "List of IDs of public subnets"
}

output "private_subnet_ids" {
  value       = module.main_vpc.private_subnets
  description = "List of IDs of private subnets"
}
