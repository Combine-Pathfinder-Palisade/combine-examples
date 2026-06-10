# terraform-provider-combine

Terraform provider for managing Combine TAP resources (users, groups, AWS roles).

**Status:** v0 skeleton. `combine_tap_user` is implemented; other resources are stubs.

## Resources

| Resource | Status |
|---|---|
| `combine_tap_user` | implemented |
| `combine_tap_group` | stub |
| `combine_tap_user_group_membership` | stub |
| `combine_tap_aws_role` | stub |

## Authentication

The provider authenticates to the TAP backend via mTLS — every API call is made *as* a specific admin user whose certificate is presented. There is no token / service-account auth path.

Provider config:

```hcl
provider "combine" {
  endpoint         = "https://tap.example.com/tap"
  client_cert_path = "/path/to/client.crt"
  client_key_path  = "/path/to/client.key"
  ca_cert_path     = "/path/to/ca.crt"
}
```

All fields fall back to env vars `COMBINE_TAP_ENDPOINT`, `COMBINE_TAP_CLIENT_CERT`, `COMBINE_TAP_CLIENT_KEY`, `COMBINE_TAP_CA_CERT`.

The cert must belong to an active admin user. Cert rotation is the operator's responsibility — reissue in the dashboard and update the secret/file the provider reads.

### Loading material from AWS Secrets Manager

Any of `endpoint`, `client_cert_path`, `client_key_path`, `ca_cert_path` can be replaced by a `*_secret_id` field that names an AWS Secrets Manager secret. The provider fetches each secret's plaintext at configure time and uses it directly — no files written to disk.

```hcl
provider "combine" {
  client_cert_secret_id = "combine/tap/admin/cert"
  client_key_secret_id  = "combine/tap/admin/key"
  ca_cert_secret_id     = "combine/tap/ca-chain"
  endpoint_secret_id    = "combine/tap/endpoint"
  aws_region            = "us-east-1"  # optional; falls back to AWS SDK chain
}
```

`*_path` and `*_secret_id` are mutually exclusive per field — set one or the other. AWS credentials are resolved via the standard SDK chain (env vars, shared config, IAM instance/role) by default. For local testing you can inline static credentials with `aws_access_key_id` + `aws_secret_access_key` (both must be set together); prefer the SDK chain in production. Secrets must be `SecretString` (text); binary secrets aren't supported.

## Local development

Requires **Go 1.22+** (terraform-plugin-framework v1.13 dropped support for older Go). On macOS: `brew upgrade go`.

```sh
go mod tidy        # fetch dependencies (first time only)
make install       # builds and installs to ~/.terraform.d/plugins/...
make test          # unit tests
make testacc       # acceptance tests (requires a running TAP backend)
```

Acceptance tests expect a local TAP via the `start-tap` workflow and the env vars above.

## Caveats

- Out-of-band changes via the TAP dashboard will be reverted on the next `terraform apply`. This is standard Terraform behavior but worth flagging — TAP admins won't expect it.
- `bundle_path` and `common_name` are silently ignored by the PUT endpoint, so the provider treats changes to them as destroy + recreate.
- The cert bundle is delivered to the operator's filesystem via `bundle_output_path` (optional). Bundle bytes never enter Terraform state. Reissue/rebuild stay in the dashboard.

## Provider address

For installation via filesystem mirror, the address is `registry.terraform.io/combine-pathfinder-palisade/combine`. Future Registry publication will use the same address.
