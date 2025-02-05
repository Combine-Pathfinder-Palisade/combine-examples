terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_partition" "current" {}
data "tls_certificate" "this" {
  url = var.cluster_oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "eks_oidc_provider" {
  url             = var.cluster_oidc_issuer_url
  client_id_list  = [var.oidc_audience]
  thumbprint_list = data.tls_certificate.this.certificates[*].sha1_fingerprint

  tags = merge(
    { Name = "${var.cluster_name}-eks-irsa" },
    var.tags
  )
}
