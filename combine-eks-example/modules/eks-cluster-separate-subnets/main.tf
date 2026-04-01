locals {
  combine_bootstrap_script_addition = !var.is_combine_env ? "" : <<EOF
  # Add Combine CA to system cert store
  echo ${var.combine_ca_chain_b64} | base64 -d > /etc/pki/ca-trust/source/anchors/combine-ca-chain.cert
  sudo update-ca-trust extract
  EOF 
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.57.0"
    }
    local = {
      source = "hashicorp/local"
      version = "~> 2.1"
    }
  }
}

data "aws_partition" "current" {}

module "eks" {
  source = "../upstream/terraform-aws-eks/v20.17.2"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = false

  cluster_addons = {
    vpc-cni = {
      most_recent       = true
      resolve_conflicts = "OVERWRITE"
    }
    kube-proxy = {
      most_recent       = true
      resolve_conflicts = "OVERWRITE"
    }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.pod_subnet_ids

  cluster_encryption_config = {}

  cluster_security_group_additional_rules = {
    cluster_ingress = {
      type        = "ingress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = var.cluster_security_group_additional_cidr_blocks
    }
  }

  iam_role_name                 = "PROJECT_${var.cluster_name}"
  iam_role_use_name_prefix      = true
  iam_role_permissions_boundary = var.iam_role_permissions_boundary_arn

  eks_managed_node_group_defaults = {
    instance_types = ["t3.medium", "t3.large", "t3.xlarge"]
  }

  enable_cluster_creator_admin_permissions = false

# Add access entry for cluster admin
#   access_entries = {
#     cluster_admin = {
#       principal_arn = var.cluster_admin_arn
#       type          = "STANDARD"

#       policy_associations = {
#         admin = {
#           policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
#           access_scope = {
#             type = "cluster"
#           }
#         }
#       }
#     }
#   }

#   tags = var.tags
}

