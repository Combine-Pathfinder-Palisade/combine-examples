# 🧪 Combine Endpoint Terraform Test Suite 🧪

This Terraform module provisions a subset of test resources inside a Combine environment as an end to end test.

## What it does

- Provisions:
  - S3 bucket
  - SQS queues (`Test`, `TestRedrive`)
  - IAM Role + Policy
  - CloudWatch alarm

## Usage

1. Create a `terraform.tfvars`:

```hcl
access_key           = "your-account-access-key"
secret_key           = "your-account-secret-key"
custom_ca_bundle     = "/path/to/combine-ca-chain.cert.pem"
subnet_1             = "your-combine-customer-subnet-id"
subnet_2             = "your-combine-customer-subnet-id"
subnet_3             = "your-combine-customer-subnet-id"
vpc_id               = "your-vpc-id"
bucket_principal_arn = your-bucket-principal-arn"
account_id           = "your-aws-account-id"
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

- Add more resources
- Add test logic via `null_resource` + `local-exec` or EC2 + script runner