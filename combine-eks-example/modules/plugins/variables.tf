###################
# Plugin Variables 
###################
variable "enable_aws_cluster_autoscaler" {
  description = "Enable the AWS Cluster Autoscaler EKS plugin"
  type        = bool
  default     = false
}

variable "enable_aws_ebs_csi_driver" {
  description = "Enable the AWS EBS CSI Driver EKS plugin"
  type        = bool
  default     = false
}

variable "enable_aws_efs_csi_driver" {
  description = "Enable the AWS AWS EFS CSI Driver EKS plugin"
  type        = bool
  default     = false
}

variable "enable_aws_external_dns" {
  description = "Enable the AWS External DNS EKS plugin"
  type        = bool
  default     = false
}

variable "enable_aws_fluentbit_node" {
  description = "Enable the AWS Fluentbit Node EKS plugin"
  type        = bool
  default     = false
}

variable "enable_aws_ingress_nginx" {
  description = "Enable the AWS Ingress NGINX EKS plugin"
  type        = bool
  default     = false
}

variable "enable_aws_loadbalancer_controller" {
  description = "Enable the AWS Load Balancer Controller EKS plugin"
  type        = bool
  default     = false
}

variable "enable_aws_metrics_server" {
  description = "Enable the AWS Metric Server EKS plugin"
  type        = bool
  default     = false
}

variable "enable_aws_secrets_store_csi_driver" {
  description = "Enable the AWS Secrets Store CSI Driver EKS plugin"
  type        = bool
  default     = false
}

variable "enable_sequoia_aws_imds_proxy" {
  description = "Enable the Sequoia AWS IMDS EKS plugin"
  type        = bool
  default     = false
}

###################
# Common Variables
###################
variable "aws_ca_cert_path" {
  description = "Path to the CA certificate file used to communicate securely with AWS services."
  type        = string
}

variable "aws_endpoint" {
  description = "Specifies the AWS service endpoint."
  type        = string
  default     = "amazonaws.com"
}

variable "aws_region" {
  description = "Specifies the AWS region where resources will be deployed."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "The AWS profile to use to authenticate with AWS"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "The EKS Cluster's certificate authority"
  type        = string
}

variable "cluster_endpoint" {
  description = "The EKS Cluster's API endpoint"
  type        = string
}

variable "cluster_name" {
  description = "Name of the Amazon EKS cluster the aws load balancer controller is being deployed to."
  type        = string
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

variable "is_combine_env" {
  description = "Is the aws load balancer controller being deployed to Combine."
  type        = bool
  default     = false
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

variable "plugins_namespace" {
  description = "Name of the Kubernetes namespace to deploy the EKS plugins to"
  type        = string
  default     = "kube-system"
}

###############################
# AWS Load Balancer Controller 
###############################
variable "aws_loadbalancer_controller_chart_version" {
  description = "The version of the aws load balancer controller helm chart."
  type        = string
}

variable "aws_loadbalancer_controller_image" {
  description = "Image details for the aws load balancer controller."
  type = object({
    repository  = string
    tag         = string
    pull_policy = string
  })
}

variable "aws_loadbalancer_controller_role_name" {
  description = "Name of the IAM role used by AWS components."
  type        = string
  default     = "PROJECT_aws-loadbalancer-controller"
}

variable "aws_loadbalancer_controller_service_account_name" {
  description = "Name of the Kubernetes service account used by AWS components."
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "sequoia_imds_proxy_port" {
  description = "The host http port to communicate with the IMDS proxy"
  type        = number
  default     = 18080
}

#####################
# AWS EBS CSI Driver
#####################
variable "ebs_csi_driver_chart_version" {
  description = "The version of the aws load balancer controller helm chart."
  type        = string
}

variable "ebs_csi_driver_controller_role_name" {
  description = "Name of the IAM role used by the ebs csi driver controller."
  type        = string
  default     = "PROJECT_aws-ebs-csi-driver-controller"
}

variable "ebs_csi_driver_controller_service_account_name" {
  description = "Name of the Kubernetes service account used by the ebs csi driver controller."
  type        = string
  default     = "ebs-csi-controller-sa"
}

variable "ebs_csi_driver_image" {
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

variable "ebs_csi_driver_node_role_name" {
  description = "Name of the IAM role used by the ebs csi driver node."
  type        = string
  default     = "PROJECT_aws-ebs-csi-driver-node"
}

variable "ebs_csi_driver_node_service_account_name" {
  description = "Name of the Kubernetes service account used by the ebs csi driver node."
  type        = string
  default     = "ebs-csi-node-sa"
}

#########################
# Seqouia AWS IMDS Proxy
#########################
variable "sequoia_aws_imds_proxy_allowed_ips_log_delay" {
  description = "Time betweeen allowed IPs log messages in minutes"
  type        = number
  default     = 1
}

variable "sequoia_aws_imds_proxy_chart_version" {
  description = "The version of the IMDS proxy Helm chart to deploy"
  type        = string
  default     = "1.1.0"
}

variable "sequoia_aws_imds_proxy_container_http_port" {
  description = "The port the IMDS proxy will run on"
  type        = number
  default     = 8080
}

variable "sequoia_aws_imds_proxy_host_http_port" {
  description = "The port the IMDS proxy will be avaiable on within the cluster"
  type        = number
  default     = 18080
}

variable "sequoia_aws_imds_proxy_image" {
  description = "Image details for the imds proxy"
  type = object({
    repository  = string
    tag         = string
    pull_policy = string
  })
}

variable "sequoia_aws_imds_proxy_target_region" {
  description = "The region the IMDS will replace the retrieved commercial region with"
  type        = string
  default     = "us-east-1"
}
