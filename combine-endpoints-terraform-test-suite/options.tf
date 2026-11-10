# NOTE: Kept out of variables.tf, which combine-test-setup.sh overwrites from SSM on every run.
variable "long_tests" {
  description = "Create the slow resources (RDS cluster and instance). Disable for quicker debugging runs."
  type        = bool
  default     = true
}
