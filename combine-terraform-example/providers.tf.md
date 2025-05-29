# providers.tf
```
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.48.0"
    }
  }
}

provider "aws" {
  region     = "us-iso-east-1"
  access_key = "<obtained-from-CAP-API>"
  secret_key = "<obtained-from-CAP-API>"
  skip_metadata_api_check = true
  custom_ca_bundle = /path/to/ca-chain.cert.pem
}
```