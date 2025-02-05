locals {
  aws_lb_debug_manifests = var.helm_debug_enable ? data.helm_template.this[0].manifests : {}

  lb_controller_role_arn = module.aws_lb_controller_irsa_role.iam_role_arn
  lb_controller_extra_volumes = [
    {
      name = "aws-ca-cert-aws-lb-controller"
      configMap = {
        defaultMode = 420
        name        = "aws-ca-cert-aws-lb-controller"
      }
    }
  ]
  lb_controller_extra_volume_mounts = [
    {
      name      = "aws-ca-cert-aws-lb-controller"
      mountPath = "/aws-ca-cert.pem"
      subPath   = "ca.crt"
      readOnly  = true
    }
  ]
  lb_controller_env = {
    AWS_CA_BUNDLE = "/aws-ca-cert.pem"
  }

  lb_controller_values = {
    region       = var.aws_region
    enableShield = false # Not available in Combine
    pullPolicy   = "Always"
    awsCaCert    = file(var.aws_ca_cert_path)
    clusterName  = var.cluster_name
    enableWaf    = false
    enableWafv2  = false
    enableShield = false

    image = {
      repository = var.image.repository
      tag        = var.image.tag
      pullPolicy = var.image.pull_policy
    }

    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = local.lb_controller_role_arn
        "eks.amazonaws.com/audience" = var.oidc_audience
      }
    }

    extraVolumeMounts = var.is_combine_env ? local.lb_controller_extra_volume_mounts : []

    env = var.is_combine_env ? local.lb_controller_env : null

    logLevel     = "debug"
    replicaCount = 1

    livenesProbe = {
      failureThreshold = 2
      httpGet = {
        path   = "/healthz"
        port   = 61779
        scheme = "HTTP"
      }
      initialDelaySeconds = var.is_combine_env ? 180 : 10
    }

    extraVolumes = concat([
      {
        name = "aws-iam-token"
        projected = {
          defaultMode = 420
          sources = [
            {
              serviceAccountToken = {
                audience          = var.oidc_audience
                expirationSeconds = 84600
                path              = "token"
              }
            }
          ]
        }
      }
    ], var.is_combine_env ? local.lb_controller_extra_volumes : [])
  }
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

module "aws_lb_controller_irsa_role" {
  source = "../../../upstream/terraform-aws-iam/5.38.0/modules/iam-role-for-service-accounts-eks/"

  attach_load_balancer_controller_policy = true
  role_name                              = var.role_name
  role_permissions_boundary_arn          = var.iam_role_permissions_boundary_arn

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.namespace}:${var.service_account_name}"]
    }
  }

  policy_name_prefix = "PROJECT_"
}

resource "helm_release" "aws_lb_controller" {
  count            = var.helm_debug_enable ? 0 : 1
  name             = "aws-load-balancer-controller"
  chart            = "${path.module}/charts/aws-load-balancer-controller/${var.chart_version}/"
  namespace        = var.namespace
  create_namespace = false
  values           = [jsonencode(local.lb_controller_values)]

  # This sleep provides time for users of the load balancer controller to clean up their resources.
  provisioner "local-exec" {
    when    = destroy
    command = "sleep 5"
  }
}

data "helm_template" "this" {
  count     = var.helm_debug_enable ? 1 : 0
  name      = "aws-load-balancer-controller"
  chart     = "${path.module}/charts/aws-ebs-csi-driver/${var.chart_version}/"
  namespace = var.namespace
  values    = [jsonencode(local.lb_controller_values)]
}

resource "local_file" "this" {
  for_each = local.aws_lb_debug_manifests
  filename = "${var.helm_debug_path}/${each.key}"
  content  = each.value
}
