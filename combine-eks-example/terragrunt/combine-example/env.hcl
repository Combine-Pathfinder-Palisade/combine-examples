locals {
  aws_account_id   = "123456789012"
  ecr_account_id   = local.aws_account_id
  ecr_collection   = "combine-eks"
  environment      = "combine-example"
  resource_prefix  = local.environment
  default_aws_tags = {
    "environment" = local.environment
  }

  aws_region        = "us-iso-east-1"
  aws_endpoint      = "c2s.ic.gov"
  aws_profile       = "WLDEVELOPER"
  aws_state_profile = "WLDEVELOPER"

  is_combine_env   = true
  aws_ca_cert_path = "/home/ec2-user/combine-example/certificates/ca-chain.cert.pem"
}