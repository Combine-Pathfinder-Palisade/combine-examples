module "aws_loadbalancer_controller" {
  source = "./modules/aws-load-balancer-controller"
  count  = var.enable_aws_loadbalancer_controller ? 1 : 0

  aws_ca_cert_path                  = var.aws_ca_cert_path
  aws_endpoint                      = var.aws_endpoint
  aws_region                        = var.aws_region
  chart_version                     = var.aws_loadbalancer_controller_chart_version
  cluster_name                      = var.cluster_name
  helm_debug_enable                 = var.helm_debug_enable
  helm_debug_path                   = var.helm_debug_path
  iam_role_permissions_boundary_arn = var.iam_role_permissions_boundary_arn
  image                             = var.aws_loadbalancer_controller_image
  is_combine_env                    = var.is_combine_env
  namespace                         = var.plugins_namespace
  oidc_audience                     = var.oidc_audience
  oidc_provider_arn                 = var.oidc_provider_arn
  role_name                         = var.aws_loadbalancer_controller_role_name
  service_account_name              = var.aws_loadbalancer_controller_service_account_name
}

module "aws_cluster_autoscaler" {
  source = "./modules/cluster-autoscaler"
  count  = var.enable_aws_cluster_autoscaler ? 1 : 0
}

module "aws_ebs_csi_driver" {
  source = "./modules/ebs-csi-driver"
  count  = var.enable_aws_ebs_csi_driver ? 1 : 0

  aws_ca_cert_path                  = var.aws_ca_cert_path
  aws_region                        = var.aws_region
  chart_version                     = var.ebs_csi_driver_chart_version
  controller_role_name              = var.ebs_csi_driver_controller_role_name
  controller_service_account_name   = var.ebs_csi_driver_controller_service_account_name
  helm_debug_enable                 = var.helm_debug_enable
  helm_debug_path                   = var.helm_debug_path
  iam_role_permissions_boundary_arn = var.iam_role_permissions_boundary_arn
  is_combine_env                    = var.is_combine_env
  image                             = var.ebs_csi_driver_image
  namespace                         = var.plugins_namespace
  node_role_name                    = var.ebs_csi_driver_node_role_name
  node_service_account_name         = var.ebs_csi_driver_node_service_account_name
  oidc_audience                     = var.oidc_audience
  oidc_provider_arn                 = var.oidc_provider_arn
  sequoia_imds_proxy_port           = var.is_combine_env ? module.aws_sequoia_aws_imds_proxy[0].proxy_port : ""
}

module "aws_efs_csi_driver" {
  source = "./modules/efs-csi-driver"
  count  = var.enable_aws_efs_csi_driver ? 1 : 0
}

module "aws_external_dns" {
  source = "./modules/external-dns"
  count  = var.enable_aws_external_dns ? 1 : 0
}

module "aws_fluentbit_node" {
  source = "./modules/fluentbit-node"
  count  = var.enable_aws_fluentbit_node ? 1 : 0
}

module "aws_sequoia_aws_imds_proxy" {
  source = "./modules/imds-proxy"
  count  = var.enable_sequoia_aws_imds_proxy ? 1 : 0

  alllowed_ips_log_delay = var.sequoia_aws_imds_proxy_allowed_ips_log_delay
  chart_version          = var.sequoia_aws_imds_proxy_chart_version
  container_http_port    = var.sequoia_aws_imds_proxy_container_http_port
  host_http_port         = var.sequoia_aws_imds_proxy_host_http_port
  image                  = var.sequoia_aws_imds_proxy_image
  namespace              = var.plugins_namespace
  target_region          = var.sequoia_aws_imds_proxy_target_region
}

module "aws_ingress_nginx" {
  source = "./modules/ingress-nginx"
  count  = var.enable_aws_ingress_nginx ? 1 : 0
}

module "aws_metrics_server" {
  source = "./modules/metrics-server"
  count  = var.enable_aws_metrics_server ? 1 : 0
}

module "aws_secrets_store_csi_driver" {
  source = "./modules/secrets-store-csi-driver-provider"
  count  = var.enable_aws_secrets_store_csi_driver ? 1 : 0
}
