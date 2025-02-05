locals {
  imds_proxy_debug_manifests = var.helm_debug_enable ? data.helm_template.this[0].manifests : {}

  imds_proxy_values = {
    image = {
      repository = var.image.repository
      tag        = var.image.tag
      pullPolicy = var.image.pull_policy
    }

    proxy = {
      targetRegion       = var.target_region
      containerHttpPort  = var.container_http_port
      hostHttpPort       = var.host_http_port
      allowedIPsLogDelay = var.alllowed_ips_log_delay
      refreshIPsDelay    = 1
    }
  }
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

resource "helm_release" "sequoia_imds_proxy" {
  count            = var.helm_debug_enable ? 0 : 1
  name             = "imds-proxy"
  chart            = "${path.module}/charts/imds-proxy/${var.chart_version}/"
  namespace        = var.namespace
  create_namespace = false
  values           = [jsonencode(local.imds_proxy_values)]
}

data "helm_template" "this" {
  count     = var.helm_debug_enable ? 1 : 0
  name      = "imds-proxy"
  chart     = "${path.module}/charts/imds-proxy/${var.chart_version}/"
  namespace = var.namespace
  values    = [jsonencode(local.imds_proxy_values)]
}

resource "local_file" "this" {
  for_each = local.imds_proxy_debug_manifests
  filename = "${var.helm_debug_path}/${each.key}"
  content  = each.value
}
