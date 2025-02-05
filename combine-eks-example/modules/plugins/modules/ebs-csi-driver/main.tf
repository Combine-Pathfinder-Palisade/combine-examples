locals {
  ebs_csi_driver_debug_manifests = var.helm_debug_enable ? data.helm_template.this[0].manifests : {}

  ebs_csi_driver_extra_volumes = [
    {
      name = "aws-ca-cert-aws-ebs-csi-driver"
      configMap = {
        defaultMode = 420
        name        = "aws-ca-cert-aws-ebs-csi-driver"
      }
    }
  ]
  ebs_csi_driver_extra_volume_mounts = [
    {
      name      = "aws-ca-cert-aws-ebs-csi-driver"
      mountPath = "/aws-ca-cert.pem"
      subPath   = "ca.crt"
      readOnly  = true
    }
  ]
  ebs_csi_driver_combine_env = [
    {
      name  = "AWS_CA_BUNDLE"
      value = "/aws-ca-cert.pem"
    },
    # {
    #   name = "HOST_IP"
    #   valueFrom = {
    #     fieldRef = {
    #       fieldPath = "status.hostIP"
    #     }
    #   }
    # },
    # {
    #   name  = "AWS_EC2_METADATA_SERVICE_ENDPOINT"
    #   value = "http://$(HOST_IP):${var.sequoia_imds_proxy_port}"
    # }
  ]

  ebs_csi_driver_values = {
    image = {
      pullPolicy = var.image.pull_policy
      repository = "${var.image.root_repository}/aws-ebs-csi-driver"
      tag        = var.image.driver_tag
    }

    sidecars = {
      provisioner = {
        env = var.is_combine_env ? local.ebs_csi_driver_combine_env : null
        image = {
          pullPolicy = var.image.pull_policy
          repository = "${var.image.root_repository}/external-provisioner"
          tag        = var.image.provisioner_tag
        }
      }

      attacher = {
        env = var.is_combine_env ? local.ebs_csi_driver_combine_env : null
        image = {
          pullPolicy = var.image.pull_policy
          repository = "${var.image.root_repository}/external-attacher"
          tag        = var.image.attacher_tag
        }
      }

      snapshotter = {
        env = var.is_combine_env ? local.ebs_csi_driver_combine_env : null
        image = {
          pullPolicy = var.image.pull_policy
          repository = "${var.image.root_repository}/external-snappshotter/csi-snapshotter"
          tag        = var.image.snapshotter_tag
        }
      }

      livenessProbe = {
        image = {
          pullPolicy = var.image.pull_policy
          repository = "${var.image.root_repository}/livenessprobe"
          tag        = var.image.livenessprobe_tag
        }
      }

      resizer = {
        env = var.is_combine_env ? local.ebs_csi_driver_combine_env : null
        image = {
          pullPolicy = var.image.pull_policy
          repository = "${var.image.root_repository}/external-resizer"
          tag        = var.image.resizer_tag
        }
      }

      nodeDriverRegistrar = {
        env = var.is_combine_env ? local.ebs_csi_driver_combine_env : null
        image = {
          pullPolicy = var.image.pull_policy
          repository = "${var.image.root_repository}/node-driver-registrar"
          tag        = var.image.nodeDriverRegistrar_tag
        }
      }

      volumemodifier = {
        env = var.is_combine_env ? local.ebs_csi_driver_combine_env : null
        image = {
          pullPolicy = var.image.pull_policy
          repository = "${var.image.root_repository}/volume-modifier-for-k8s"
          tag        = var.image.volumemodifier_tag
        }
      }
    }

    controller = {
      env    = var.is_combine_env ? local.ebs_csi_driver_combine_env : null
      region = var.aws_region

      serviceAccount = {
        name = var.controller_service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = module.aws_ebs_csi_driver_controller_irsa_role.iam_role_arn
          "eks.amazonaws.com/audience" = var.oidc_audience
        }
      }

      volumes = concat([
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
      ], var.is_combine_env ? local.ebs_csi_driver_extra_volumes : [])

      volumeMounts = var.is_combine_env ? local.ebs_csi_driver_extra_volume_mounts : []
    }

    node = {
      env = var.is_combine_env ? local.ebs_csi_driver_combine_env : null

      serviceAccount = {
        name = var.node_service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = module.aws_ebs_csi_driver_node_irsa_role.iam_role_arn
          "eks.amazonaws.com/audience" = var.oidc_audience
        }
      }


      volumes = concat([
        {
          name = "aws-iam-token"
          projected = {
            serviceAccountToken = {
              audience          = var.oidc_audience
              expirationSeconds = 84600
              path              = "token"
            }
          }
        }
      ], var.is_combine_env ? local.ebs_csi_driver_extra_volumes : [])


      volumeMounts = var.is_combine_env ? local.ebs_csi_driver_extra_volume_mounts : []
    }

    awsCaCert = file(var.aws_ca_cert_path)
  }
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

module "aws_ebs_csi_driver_controller_irsa_role" {
  source = "../../../upstream/terraform-aws-iam/5.38.0/modules/iam-role-for-service-accounts-eks/"

  attach_ebs_csi_policy         = true
  role_name                     = var.controller_role_name
  role_permissions_boundary_arn = var.iam_role_permissions_boundary_arn

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.namespace}:${var.controller_service_account_name}"]
    }
  }

  policy_name_prefix = "PROJECT_"

}

module "aws_ebs_csi_driver_node_irsa_role" {
  source = "../../../upstream/terraform-aws-iam/5.38.0/modules/iam-role-for-service-accounts-eks/"

  attach_ebs_csi_policy         = true
  role_name                     = var.node_role_name
  role_permissions_boundary_arn = var.iam_role_permissions_boundary_arn

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.namespace}:${var.node_service_account_name}"]
    }
  }

  policy_name_prefix = "PROJECT_"

}

resource "helm_release" "aws_ebs_csi_driver" {
  count            = var.helm_debug_enable ? 0 : 1
  name             = "aws-ebs-csi-driver"
  chart            = "${path.module}/charts/aws-ebs-csi-driver/${var.chart_version}/"
  namespace        = var.namespace
  create_namespace = false
  values           = [jsonencode(local.ebs_csi_driver_values)]

  # This sleep provides time for users of the csi driver to clean up their resources.
  provisioner "local-exec" {
    when    = destroy
    command = "sleep 5"
  }
}

data "helm_template" "this" {
  count     = var.helm_debug_enable ? 1 : 0
  name      = "aws-ebs-csi-driver"
  chart     = "${path.module}/charts/aws-ebs-csi-driver/${var.chart_version}/"
  namespace = var.namespace
  values    = [jsonencode(local.ebs_csi_driver_values)]
}

resource "local_file" "this" {
  for_each = local.ebs_csi_driver_debug_manifests
  filename = "${var.helm_debug_path}/${each.key}"
  content  = each.value
}
