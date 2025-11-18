
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.48.0"
    }
  }
}

locals {
  access_key       = var.access_key
  secret_key       = var.secret_key
  custom_ca_bundle = var.custom_ca_bundle
}

# access key and secret key can be sourced from the CAP api, or sourced via
# environment variables, see https://registry.terraform.io/providers/hashicorp/aws/latest/docs#provider-configuration
provider "aws" {
  region                  = "us-iso-east-1" # change if your emulated region is different
  access_key              = local.access_key
  secret_key              = local.secret_key
  skip_metadata_api_check = true
  custom_ca_bundle        = local.custom_ca_bundle
}

provider "aws" {
  alias                   = "west"
  region                  = "us-iso-east-1"
  access_key              = local.access_key
  secret_key              = local.secret_key
  custom_ca_bundle        = local.custom_ca_bundle
  skip_metadata_api_check = true
}
