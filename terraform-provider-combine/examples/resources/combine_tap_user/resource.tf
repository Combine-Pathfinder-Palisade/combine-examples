# ── Before you apply ──────────────────────────────────────────────────────
# This file is a template, not a drop-in. The provider validates none of the
# values below at plan time — bad values fail server-side during apply. Edit:
#
#   1. email     — must use a domain TAP allows. "example.com" will be rejected.
#   2. user_role — the cert in provider.tf must be allowed to create this role.
#   3. aws_role_ids — must be IDs that exist in YOUR TAP (see the dashboard or
#      the aws-roles API). The IDs below are from a different environment and
#      will fail attachment if they don't exist in yours.
#
# Also: the provider authenticates as the admin user whose cert is configured
# in provider.tf — that user must be active and permitted to create users.
# ──────────────────────────────────────────────────────────────────────────

resource "combine_tap_user" "alice" {
  email     = "alice@example.com"
  full_name = "Alice Example"
  user_role = "admin"
  active    = true

  # AWS role IDs to attach. Replace with real IDs from your TAP environment.
  aws_role_ids = ["251", "1838", "2289", "2733", "1007"]

  # Optional: download the cert bundle to disk on create. The bundle bytes
  # never enter Terraform state. The path is the operator's filesystem; the
  # provider creates the parent directory if it doesn't exist.
  bundle_output_path = "${path.module}/bundles/alice.pfx"
}

output "alice_id" {
  value = combine_tap_user.alice.id
}

output "alice_bundle_url" {
  value     = combine_tap_user.alice.bundle_url
  sensitive = true
}
