locals {
  azs = [for az in var.availability_zones : "${var.aws_region}${az}"]

  private_cidr_block = cidrsubnet(var.cidr_block, 2, 0)
  public_cidr_block  = cidrsubnet(var.cidr_block, 2, 1)

  private_subnets = [
    for idx in range(0, length(local.azs)) : cidrsubnet(local.private_cidr_block, 2, idx)
  ]
  public_subnets = [
    for idx in range(0, length(local.azs)) : cidrsubnet(local.public_cidr_block, 2, idx)
  ]
}

module "main_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.7.0"

  name                  = var.vpc_name
  cidr                  = var.cidr_block
  secondary_cidr_blocks = var.additional_cidr_blocks
  azs                   = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  create_igw           = var.create_internet_gateway
  enable_nat_gateway   = true
  enable_dns_hostnames = true
  single_nat_gateway   = false
  vpc_tags             = var.vpc_tags
}
