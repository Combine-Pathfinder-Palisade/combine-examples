variable "alllowed_ips_log_delay" {
  description = "Time betweeen allowed IPs log messages in minutes"
  type        = number
  default     = 1
}

variable "chart_version" {
  description = "The version of the IMDS proxy Helm chart to deploy"
  type        = string
  default     = "1.1.0"
}

variable "container_http_port" {
  description = "The port the IMDS proxy will run on"
  type        = number
  default     = 8080
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

variable "host_http_port" {
  description = "The port the IMDS proxy will be avaiable on within the cluster"
  type        = number
  default     = 18080
}

variable "image" {
  description = "Image details for the imds proxy"
  type = object({
    repository  = string
    tag         = string
    pull_policy = string
  })
}

variable "namespace" {
  description = "The namespace to deploy the IMDS proxy to"
  type        = string
  default     = "kube-system"
}

variable "target_region" {
  description = "The region the IMDS will replace the retrieved commercial region with"
  type        = string
  default     = "us-east-1"
}
