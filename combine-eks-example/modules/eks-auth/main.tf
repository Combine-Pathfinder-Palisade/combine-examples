data "aws_partition" "current" {}

import {
  to = kubernetes_config_map_v1.aws_auth
  id = "kube-system/aws-auth"
}

locals {
  aws_auth_admin_users          = var.use_access_entries ? [] : var.admin_users
  aws_auth_admin_role_arns      = var.use_access_entries ? [] : var.admin_role_arns
  aws_auth_node_group_role_arns = var.use_access_entries ? [] : var.node_group_role_arns

  access_entry_admin_users     = var.use_access_entries ? var.admin_users : []
  access_entry_admin_role_arns = var.use_access_entries ? var.admin_role_arns : []
}

resource "kubernetes_config_map_v1" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode(concat(
      [for role in local.aws_auth_node_group_role_arns : {
        rolearn  = role
        username = "system:node:{{EC2PrivateDNSName}}"
        groups   = ["system:bootstrappers", "system:nodes"]
      }],
      [for role in local.aws_auth_admin_role_arns : {
        rolearn  = role
        username = "admin-roles"
        groups   = ["system:masters"]
      }],
    ))
    mapUsers = yamlencode(concat(
      [for user in local.aws_auth_admin_users : {
        userarn  = user.arn
        username = user.username
        groups   = ["system:masters"]
      }]
    ))
  }
}

resource "aws_eks_access_entry" "admin_users" {
  for_each = { for user in local.access_entry_admin_users : user.username => user }

  cluster_name  = var.cluster_name
  principal_arn = each.value.arn
  user_name     = each.value.username
}

resource "aws_eks_access_policy_association" "admin_users" {
  for_each = { for user in local.access_entry_admin_users : user.username => user }

  cluster_name = var.cluster_name
  # policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = each.value.arn

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_access_entry" "admin_roles" {
  for_each = toset(local.access_entry_admin_role_arns)

  cluster_name  = var.cluster_name
  principal_arn = each.key
}

resource "aws_eks_access_policy_association" "admin_roles" {
  for_each = toset(local.access_entry_admin_role_arns)

  cluster_name = var.cluster_name
  # policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = each.key

  access_scope {
    type = "cluster"
  }
}
