
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.48.0"
    }
  }
}

# access key and secret key can be sourced from the CAP api, or sourced via 
# environment variables, see https://registry.terraform.io/providers/hashicorp/aws/latest/docs#provider-configuration
provider "aws" {
  region     = "us-iso-east-1" # change if your emulated region is different
  access_key = "<obtained-from-CAP-API>"
  secret_key = "<obtained-from-CAP-API>"
  skip_metadata_api_check = true
  custom_ca_bundle = /path/to/ca-chain.cert.pem
}