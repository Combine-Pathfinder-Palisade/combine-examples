include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.module_base_source_url}//eks-auth${include.root.locals.module_base_version}"
}

dependency "eks_cluster" {
  config_path  = "../eks-cluster"
  mock_outputs = include.root.locals.common_vars.mock_outputs.eks_cluster
}

locals {
  aws_region  = include.root.locals.aws_region
  aws_profile = include.root.locals.aws_profile
}

inputs = {

  cluster_name                       = dependency.eks_cluster.outputs.cluster_name
  cluster_endpoint                   = dependency.eks_cluster.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks_cluster.outputs.cluster_certificate_authority_data

  node_group_role_arns = dependency.eks_cluster.outputs.node_group_role_arns
  admin_role_arns      = ["arn:aws-iso:iam::123456789012:role/Combine-example-TS-WLDEVELOPER"]
  admin_users = [
    {
      username = "dsabbagh"
      arn      = "arn:aws-iso:iam::123456789012:user/developer-combine-example"
    }
  ]
  cluster_certificate_authority_data = dependency.eks_cluster.outputs.cluster_certificate_authority_data
  cluster_endpoint                   = dependency.eks_cluster.outputs.cluster_endpoint
  cluster_name                       = dependency.eks_cluster.outputs.cluster_name
}