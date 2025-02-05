locals {
  ecr_amazon_endpoint_root = "amazonaws.com"
  module_base_source_url   = "${get_parent_terragrunt_dir()}/../modules"
  module_base_version      = ""
  mock_outputs = {
    eks_cluster = {
      cluster_name                             = "dummy-cluster"
      cluster_certificate_authority_data       = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURCVENDQWUyZ0F3SUJBZ0lJY3FydWRLQWJZcDB3RFFZSktvWklodmNOQVFFTEJRQXdGVEVUTUJFR0ExVUUKQXhNS2EzVmlaWEp1WlhSbGN6QWVGdzB5TkRBNE1EZ3hPVFF3TVRKYUZ3MHpOREE0TURZeE9UUTFNVEphTUJVeApFekFSQmdOVkJBTVRDbXQxWW1WeWJtVjBaWE13Z2dFaU1BMEdDU3FHU0liM0RRRUJBUVVBQTRJQkR3QXdnZ0VLCkFvSUJBUURaZ1Ezc3hsYkcwUmpyZ0VpcjRUK0pqdVpKMHBqWjA1ZWFKUnZOSExvRy8yREF6QXQwa2VuNUo2OEIKQmRGWERNcmd6UVJSeXZVOFNuMGFpRTJXVUhBSWN3eGFJaUpNbFdycm9DeHJuSjZNVG13Q0k1anczOTRUTHczQgpYKzFUUFRYMEwzZFZPSmo0cmZiM1l5N1A4UDJkdFl5Tm1IWTFqdmtTS1dzcnpaN2JxVkRZSGI4aTljcHRvMW8zClhaejVRb3ZaL0xBa01FR3FvODBMTDdhL1hJbitxMHFIYVMyQVpYdk5xa1VzQVZNVkpCNVU2SndoU21RdjlHR2IKOER0OS9BZ3hHUzVRdUIyTldSWE9RNU84S1Vnd1JxOVR5SWY1YVI0QWYzQnVENlluWG1JQ2c4cGp5cjJoK05LaApoY2VzNU8wR2EranNhS1Q3TFYrQ0dBYlhOWkVEQWdNQkFBR2pXVEJYTUE0R0ExVWREd0VCL3dRRUF3SUNwREFQCkJnTlZIUk1CQWY4RUJUQURBUUgvTUIwR0ExVWREZ1FXQkJTQXNXajJNOTlFaFlhektaN1pGcERzazgvVU16QVYKQmdOVkhSRUVEakFNZ2dwcmRXSmxjbTVsZEdWek1BMEdDU3FHU0liM0RRRUJDd1VBQTRJQkFRQm5tRGNxbGh6bwp5emY4SW5jY1Q1VHRnNWxUaUJTVjNwU2Q3K1hOWVd2RmdwczFObUw1VlJTaU4xemt0RklUZ0l1TmZHUnhUNGxBCmNOSENnRXJkTlZZblNxcDFNSmVIYTI3U3VnNHlRSnNzbERGYW0rMWljZEJYT20vSTl1eEF3UmxWWElMSFpkSEcKL1hyNDZ4OUtYOGRVendsNUJQQ3p3NTl2MmJnMTY0eWkvTTBhMk8zaE81cCt6dWZ6UGRveHdtSC91M2dQa2JpOQpPczd2YVZkR1ZadGw4OVorQ3pJUUp3TmMrZm9IR2N1VHExT2F0Z3dKSENZZG1SK2pMU01VdXVpSDRVQngzNCs5CnhEODZjYmhnMnp5U2VTajdEVmx1T0lhZ2Y0eFpMaTJ6d2pMdkR1YndyRVJ1aTRkMDhDY09wMnRlNzBRVXpNaEsKejRSNEZ1SCtaM0JxCi0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0F"
      cluster_endpoint                         = "https://MOCK"
      cluster_oidc_issuer_url                  = "https://oidc.eks.us-east-1.amazonaws.com/id/MOCK_OIDC_ISSUER"
      cluster_tls_certificate_sha1_fingerprint = "MOCK"
    }
    eks_node_groups = {
      node_group_role_arns = [
        "FAKEARN1",
        "FAKEARN2",
      ]
    }
    eks_auth = {}
    oidc_provider = {
      arn = "FAKEARN3"
    }
    networking = {
      vpc_id             = "vpc-MOCK"
      public_subnet_ids  = ["subnet-MOCK1"]
      private_subnet_ids = ["subnet-MOCK2"]
    }
  }
}