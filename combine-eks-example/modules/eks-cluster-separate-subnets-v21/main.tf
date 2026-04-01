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
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

data "aws_partition" "current" {}

module "eks" {
  source = "../upstream/terraform-aws-eks/v21.3.1"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = false
  endpoint_private_access = true
  enable_irsa            = false

  addons = {
    vpc-cni = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
    }
    kube-proxy = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
    }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.pod_subnet_ids

  encryption_config = {}

  security_group_additional_rules = {
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

  enable_cluster_creator_admin_permissions = false

  access_entries = {}

  tags = var.tags
}
