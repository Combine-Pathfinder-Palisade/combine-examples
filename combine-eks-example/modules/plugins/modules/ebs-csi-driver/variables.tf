variable "aws_ca_cert_path" {
  description = "Path to the CA certificate file used to communicate securely with AWS services."
  type        = string
}

variable "aws_region" {
  description = "Specifies the AWS region where resources will be deployed."
  type        = string
  default     = "us-east-1"
}

variable "chart_version" {
  description = "The version of the aws load balancer controller helm chart."
  type        = string
}

variable "controller_role_name" {
  description = "Name of the IAM role used by the ebs csi driver controller."
  type        = string
  default     = "PROJECT_aws-ebs-csi-driver-controller"
}

variable "controller_service_account_name" {
  description = "Name of the Kubernetes service account used by the ebs csi driver controller."
  type        = string
  default     = "ebs-csi-controller-sa"
}

variable "helm_debug_enable" {
  description = "If enabled, this will render the Helm template to the path specified in the debug_path variable"
  type        = bool
  default     = false
}

variable "helm_debug_path" {
  description = "The path to render the Helm template to"
  type        = string
  default     = "./template_debug"
}

variable "iam_role_permissions_boundary_arn" {
  description = "ARN of the IAM role's permission boundary."
  type        = string
}

variable "image" {
  description = "Image details for the aws load balancer controller."
  type = object({
    pull_policy             = string
    root_repository         = string
    driver_tag              = string
    provisioner_tag         = string
    attacher_tag            = string
    snapshotter_tag         = string
    livenessprobe_tag       = string
    resizer_tag             = string
    nodeDriverRegistrar_tag = string
    volumemodifier_tag      = string
  })
}

variable "is_combine_env" {
  description = "Is the aws load balancer controller being deployed to Combine."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Name of the Kubernetes namespace to deploy the chart to"
  type        = string
  default     = "kube-system"
}

variable "node_role_name" {
  description = "Name of the IAM role used by the ebs csi driver node."
  type        = string
  default     = "PROJECT_aws-ebs-csi-driver-node"
}

variable "node_service_account_name" {
  description = "Name of the Kubernetes service account used by the ebs csi driver node."
  type        = string
  default     = "ebs-csi-node-sa"
}

variable "oidc_audience" {
  description = "Audience for OpenID Connect (OIDC) authentication."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "oidc_provider_arn" {
  description = "ARN for OpenID Connect (OIDC) AWS IAM Identity Provider."
  type        = string
}

variable "sequoia_imds_proxy_port" {
  description = "The host http port to communicate with the IMDS proxy"
  type        = number
  default     = 18080
}
