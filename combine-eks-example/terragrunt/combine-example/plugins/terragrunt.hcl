include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.module_base_source_url}//plugins${include.root.locals.module_base_version}"
}

generate "lbc-helmignore" {
  path      = "modules/aws-load-balancer-controller/charts/aws-load-balancer-controller/1.8.1/.helmignore"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
.terragrunt-source-manifest*
EOF
}

generate "ebs-csi-helmignore" {
  path      = "modules/ebs-csi-driver/charts/aws-ebs-csi-driver/2.33.0/.helmignore"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
.terragrunt-source-manifest*
EOF
}

dependency "eks_cluster" {
  config_path  = "../eks-cluster"
  mock_outputs = include.root.locals.common_vars.mock_outputs.eks_cluster
}

dependency "oidc_provider" {
  config_path  = "../oidc-provider"
  mock_outputs = include.root.locals.common_vars.mock_outputs.eks_cluster
}

locals {
  aws_account_id = include.root.locals.aws_account_id
  aws_region     = include.root.locals.aws_region
  aws_endpoint   = include.root.locals.environment_vars.aws_endpoint

  ecr_registry = "${local.aws_account_id}.dkr.ecr.${local.aws_region}.${local.aws_endpoint}/combine-eks"
}

inputs = {

  cluster_name                       = dependency.eks_cluster.outputs.cluster_name
  cluster_endpoint                   = dependency.eks_cluster.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks_cluster.outputs.cluster_certificate_authority_data

  helm_debug_enable = false

  iam_role_permissions_boundary_arn = "arn:aws-iso:iam::123456789012:policy/PB-example-WLDEVELOPER-C2E-TS"
  oidc_provider_arn                 = dependency.oidc_provider.outputs.arn

  enable_aws_load_balancer_controller       = true
  aws_loadbalancer_controller_chart_version = "1.8.1"
  aws_loadbalancer_controller_image = {
    repository  = "123456789012.dkr.ecr.${local.aws_region}.${local.aws_endpoint}/combine-eks/aws-load-balancer-controller"
    tag         = "v2.8.1"
    pull_policy = "Always"
  }

  enable_aws_ebs_csi_driver    = true
  ebs_csi_driver_chart_version = "2.33.0"
  ebs_csi_driver_image = {
    pull_policy             = "Always"
    root_repository         = "123456789012.dkr.ecr.${local.aws_region}.${local.aws_endpoint}/combine-eks"
    driver_tag              = "v1.29.1"
    provisioner_tag         = "v5.0.1-eks-1-29-17"
    attacher_tag            = "v4.6.1-eks-1-29-17"
    snapshotter_tag         = "v8.0.1-eks-1-29-17"
    livenessprobe_tag       = "v2.13.0-eks-1-29-17"
    resizer_tag             = "v1.11.1-eks-1-29-17"
    nodeDriverRegistrar_tag = "v2.11.0-eks-1-29-17"
    volumemodifier_tag      = "v0.3.0"
  }

  enable_sequoia_aws_imds_proxy        = true
  sequoia_aws_imds_proxy_chart_version = "1.1.0"
  sequoia_aws_imds_proxy_image = {
    repository  = "public.ecr.aws/sequoia/combine/imds-proxy"
    tag         = "v1.1.0"
    pull_policy = "Always"
  }
  sequoia_aws_imds_proxy_target_region = local.aws_region
}