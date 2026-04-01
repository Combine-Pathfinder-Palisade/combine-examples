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
  enable_irsa = false

  addons = {
    vpc-cni = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
    }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

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

module "managed_node_group" {
  source = "../upstream/terraform-aws-eks/v21.3.1/modules/eks-managed-node-group"
  cluster_name    = var.cluster_name
  kubernetes_version = var.kubernetes_version

  name            = "${var.cluster_name}-ng-2"
  use_name_prefix = true

  cluster_service_cidr = "172.20.0.0/16"
  subnet_ids           = var.subnet_ids

  min_size     = 1
  max_size     = 1
  desired_size = 1

  key_name = var.node_group_remote_access_key

  pre_bootstrap_user_data = <<-EOT
          #!/bin/bash
          set -ex
          ${local.combine_bootstrap_script_addition}
          EOT

  create_launch_template                 = true
  use_custom_launch_template             = true
  launch_template_name                   = "${var.cluster_name}-ng-2"
  launch_template_use_name_prefix        = true
  update_launch_template_default_version = true
  launch_template_description            = "Custom launch template for ${var.cluster_name}-ng-2 EKS managed node group"

  enable_monitoring = true

  create_iam_role               = true
  iam_role_use_name_prefix      = true
  iam_role_name                 = "PROJECT_ng-2"
  iam_role_description          = "EKS managed node group IAM role"
  iam_role_attach_cni_policy    = true
  iam_role_permissions_boundary = var.iam_role_permissions_boundary_arn

  tags = var.tags

  depends_on = [module.eks]
}