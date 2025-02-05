locals {
  common_vars      = read_terragrunt_config(find_in_parent_folders("common_vars.hcl")).locals
  environment_vars = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
  all_vars = merge(
    local.common_vars,
    local.environment_vars
  )
  module_base_source_url = local.all_vars.module_base_source_url
  module_base_version    = local.all_vars.module_base_version
  aws_account_id         = local.all_vars.aws_account_id
  aws_region             = local.all_vars.aws_region
  aws_profile            = local.all_vars.aws_profile
  aws_state_profile      = local.all_vars.aws_state_profile
  env                    = local.all_vars.environment

  default_tags = merge(
    try(local.common_vars.default_aws_tags, null),
    try(local.environment_vars.default_aws_tags, null),
    {
      "environment" = local.env,
    }
  )
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
      variable "default_tags" {
        type = map(any)
      }
provider "aws" {
  region = "${local.aws_region}"
  profile = "${local.aws_profile}"
  default_tags {
    tags = var.default_tags
  }
}
EOF
}

remote_state {
  backend = "s3"
  # allows us to disable init to just get lists of providers without querying remote state
  disable_init = tobool(get_env("TERRAGRUNT_DISABLE_INIT", "false"))
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "${local.env}-${local.aws_region}.tfstate"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    profile        = local.aws_state_profile
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}

inputs = merge(
  local.common_vars,
  local.environment_vars,
  {
    default_tags = local.default_tags
  }
)