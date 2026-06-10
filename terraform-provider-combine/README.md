# terraform-provider-combine

The `combine` provider lets you manage Combine **TAP** (Combine Dashboard) resources — users, groups, and AWS role attachments — declaratively with Terraform instead of clicking through the dashboard.

It authenticates to the TAP backend over **mTLS**: every API call is made *as* a specific admin user, identified by the client certificate you give the provider. There is no token or service-account path — the cert is the identity.

**Note that this provider will only work with Combine version 3.14, which has not been released yet.**

## Resources

This provider is an early (`v0`) release. `combine_tap_user` is fully implemented; the other resources are still stubs. Stick to `combine_tap_user` for now.

| Resource | Status |
|---|---|
| `combine_tap_user` | implemented |
| `combine_tap_group` | stub |
| `combine_tap_user_group_membership` | stub |
| `combine_tap_aws_role` | stub |

## Prerequisites

Before you start, make sure you have:

- **Terraform** `>= 1.5` installed.
- An **active TAP admin certificate** (client cert + private key) that is permitted to create users, plus the **CA cert** that signs the TAP server.
- The **TAP endpoint URL** (e.g. `https://combine-t-e-12345a6b7d8901ef.example.com/tap` or similar).

Reissue or rotate certs in the TAP dashboard — cert lifecycle stays there, not in Terraform.

## 1 — Declare and configure the provider

In your Terraform configuration, require the provider and point it at your TAP endpoint and mTLS material. You can supply that material two ways — from local files (**Option A**) or from AWS Secrets Manager (**Option B**).

### Option A — local files

```hcl
terraform {
  required_providers {
    combine = {
      source  = "registry.terraform.io/combine-pathfinder-palisade/combine"
      version = "~> 0.0.1"
    }
  }
}

provider "combine" {
  endpoint         = "https://combine-t-e-12345a6b7d8901ef.example.com/tap"
  client_cert_path = "/path/to/client.crt"
  client_key_path  = "/path/to/client.key"
  ca_cert_path     = "/path/to/ca.crt"
}
```

Every field also reads from an environment variable, so you can keep paths out of the config entirely:

| Attribute          | Environment variable      |
| ------------------ | ------------------------- |
| `endpoint`         | `COMBINE_TAP_ENDPOINT`    |
| `client_cert_path` | `COMBINE_TAP_CLIENT_CERT` |
| `client_key_path`  | `COMBINE_TAP_CLIENT_KEY`  |
| `ca_cert_path`     | `COMBINE_TAP_CA_CERT`     |

The cert must belong to an active admin user. Cert rotation is the operator's responsibility — reissue in the dashboard and update the secret/file the provider reads.

### Option B — load material from AWS Secrets Manager

Instead of files on disk, each of the four fields above has a `*_secret_id` variant that names an AWS Secrets Manager secret. The provider fetches each secret's plaintext at configure time and uses it directly — **bytes never touch disk**. This is the recommended approach for CI/CD and shared environments, where committing cert files or local paths isn't practical.

```hcl
provider "combine" {
  endpoint_secret_id    = "combine/tap/endpoint"
  client_cert_secret_id = "combine/tap/admin/cert"
  client_key_secret_id  = "combine/tap/admin/key"
  ca_cert_secret_id     = "combine/tap/ca-chain"

  aws_region = "us-east-1" # optional; falls back to the AWS SDK config chain
                           # use "us-iso-east-1" or target region id if running inside Combine
}
```

Each path-based field maps to a secret-based equivalent:

| File-based field   | Secrets Manager field   |
| ------------------ | ----------------------- |
| `endpoint`         | `endpoint_secret_id`    |
| `client_cert_path` | `client_cert_secret_id` |
| `client_key_path`  | `client_key_secret_id`  |
| `ca_cert_path`     | `ca_cert_secret_id`     |

Notes:

- `*_path` and `*_secret_id` are **mutually exclusive per field** — set one or the other, not both. You can mix approaches across fields (e.g. a file-based endpoint with secret-based certs) if you want.
- Each secret must be a **`SecretString`** (text); binary secrets aren't supported. Store the raw PEM contents of the cert/key as the secret value.
- AWS credentials resolve through the standard SDK chain (env vars, shared config, IAM instance/role). For local testing only, you can inline static creds with `aws_access_key_id` + `aws_secret_access_key` (both required together).

> **Warning — never hard-code AWS keys in `.tf` files.** Inline `aws_access_key_id` / `aws_secret_access_key` values get committed to version control. Prefer an IAM role or environment variables in any shared or production setting.

## 2 — Define a resource

Add a `combine_tap_user`. The provider does not validate these values at plan time — bad values fail server-side on `apply` — so make sure each one is real for *your* environment.

```hcl
resource "combine_tap_user" "alice" {
  email     = "alice@your-allowed-domain.com" # must use a TAP-allowed domain
  full_name = "Alice Example"
  user_role = "admin"                         # your cert must be allowed to grant this
  active    = true

  # AWS role IDs to attach — must exist in YOUR TAP (check the dashboard
  # or the aws-roles API). IDs are environment-specific.
  aws_role_ids = ["251", "1838", "2289"]

  # Optional: write the cert bundle to disk on create. Bundle bytes never
  # enter Terraform state; the provider creates the parent dir if needed.
  bundle_output_path = "${path.module}/bundles/alice.pfx"
}

output "alice_id" {
  value = combine_tap_user.alice.id
}
```

## 3 — Initialize and apply

```sh
terraform init    # download the provider
terraform plan    # preview what will be created
terraform apply   # create the user in TAP
```

That's it — `alice` now exists in TAP, with the requested role and AWS role attachments, managed entirely from code.

## Local development

Requires **Go 1.22+** (terraform-plugin-framework v1.13 dropped support for older Go). On macOS: `brew upgrade go`.

```sh
go mod tidy        # fetch dependencies (first time only)
make install       # builds and installs to ~/.terraform.d/plugins/...
make test          # unit tests
make testacc       # acceptance tests (requires a running TAP backend)
```

Acceptance tests expect a local TAP via the `start-tap` workflow and the env vars above.

## Things to know

- **Out-of-band changes are reverted.** If a TAP admin edits a Terraform-managed user through the dashboard, the next `terraform apply` reverts it. This is normal Terraform behavior, but TAP admins won't expect it — coordinate ownership.
- **Some fields force a recreate.** `bundle_path` and `common_name` are ignored by the update endpoint, so changing them triggers destroy + recreate.
- **Bundles aren't in state.** The cert bundle is delivered to your filesystem via `bundle_output_path` (optional); bundle bytes never enter Terraform state. Reissue/rebuild stay in the dashboard.
- **Cert rotation is on you.** Reissue the admin cert in the dashboard and update the file or secret the provider reads.

## Provider address

For installation via filesystem mirror, the address is `registry.terraform.io/combine-pathfinder-palisade/combine`. Future Registry publication will use the same address.
