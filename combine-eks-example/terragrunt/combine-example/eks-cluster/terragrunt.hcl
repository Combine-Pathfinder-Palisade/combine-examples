include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.module_base_source_url}//eks-cluster${include.root.locals.module_base_version}"
}

locals {
  aws_region  = include.root.locals.aws_region
  aws_profile = include.root.locals.aws_profile
}

inputs = {
  vpc_id = "vpc-12345678901234567"
  subnet_ids = [
    "subnet-12345678901234567",
    "subnet-12345678901234567",
    "subnet-12345678901234567",
    "subnet-12345678901234567",
    "subnet-12345678901234567",
    "subnet-12345678901234567",
  ]

  cluster_encryption_config                     = {}
  cluster_security_group_additional_cidr_blocks = ["10.0.0.0/16"]
  cluster_name                                  = "combine-example-eks"
  cluster_version                               = "1.30"
  cluster_endpoint_public_access                = false
  cluster_addons                                = {}

  cluster_admin_arn = "arn:aws-iso:iam::123456789012:role/Combine-example-TS-WLDEVELOPER"

  combine_ca_chain_b64 = base64encode(file(include.root.locals.environment_vars.aws_ca_cert_path))

  node_group_remote_access_key = "CombineExample"

  iam_role_permissions_boundary_arn = "arn:aws-iso:iam::123456789012:policy/PB-example-WLDEVELOPER-C2E-TS"

  tags = {}
}