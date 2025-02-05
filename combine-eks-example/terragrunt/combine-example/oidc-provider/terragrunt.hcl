include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.module_base_source_url}//oidc-provider${include.root.locals.module_base_version}"
}

generate "provider_oidc" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
      variable "default_tags" {
        type = map(any)
      }
provider "aws" {
  region = "${include.root.locals.aws_region}"
  profile = "${local.aws_profile}"
  default_tags {
    tags = var.default_tags
  }
}
EOF
}

dependency "eks_cluster" {
  config_path  = "../eks-cluster"
  mock_outputs = include.root.locals.common_vars.mock_outputs.eks_cluster
}

locals {
  aws_profile = "WLCUSTOMERIT"
}

inputs = {
  aws_profile             = local.aws_profile
  cluster_name            = dependency.eks_cluster.outputs.cluster_name
  cluster_oidc_issuer_url = dependency.eks_cluster.outputs.cluster_oidc_issuer_url
  client_id_list          = ["sts.amazonaws.com"]
}