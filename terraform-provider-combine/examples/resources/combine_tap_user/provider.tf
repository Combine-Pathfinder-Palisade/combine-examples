terraform {
  required_providers {
    combine = {
      source  = "registry.terraform.io/combine-pathfinder-palisade/combine"
      version = "~> 0.0.1"
    }
  }
}

provider "combine" {
  # mTLS material and the TAP endpoint are pulled from AWS Secrets Manager.
  # Each secret's SecretString is read at provider configure time; bytes never
  # touch disk. Create these four secrets in AWS first (names below are
  # placeholders — adjust to match your account).
  endpoint_secret_id    = "combine/tap/endpoint"
  client_cert_secret_id = "combine/tap/admin/cert"
  client_key_secret_id  = "combine/tap/admin/key"
  ca_cert_secret_id     = "combine/tap/ca-chain"

  # AWS credentials for the Secrets Manager calls above. For local testing,
  # inline static creds are fine — replace the placeholders below. For
  # production, drop these fields and use the SDK chain (env vars, shared
  # config, or an IAM role).
  # set aws_region to the emulated target region if running inside of Combine.
  aws_region            = "us-east-1"
  aws_access_key_id     = "ASIA1234567890123456"
  aws_secret_access_key = "SecretKeyThatIsSuperSecretForSecretThing"
}
