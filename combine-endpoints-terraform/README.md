# Combine Endpoint Terraform Test Suite

This Terraform module provisions a subset of test resources inside the Combine environment to replace manual `tests.txt` CLI commands.

## What it does

- Provisions:
  - S3 bucket
  - SQS queues (`Test`, `TestRedrive`)
  - IAM Role + Policy
  - CloudWatch alarm

## Usage

1. Fill in `terraform.tfvars`:

```hcl
region           = "us-iso-east-1"
access_key       = "your_combine_access_key"
secret_key       = "your_combine_secret_key"
custom_ca_bundle = "./combine-ca-chain.cert.pem"
s3_endpoint      = "https://s3.us-iso-east-1.c2s.ic.gov"
sqs_endpoint     = "https://sqs.us-iso-east-1.c2s.ic.gov"
```

2. Run Terraform:

```bash
terraform init
terraform apply
```

3. When done:

```bash
terraform destroy
```

## Next Steps

- Add more resources from `tests.txt`
- Add test logic via `null_resource` + `local-exec` or EC2 + script runner