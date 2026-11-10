#!/bin/bash

#############################
# WORK IN PROGRESS
#
# cli-test-suite.sh
#
# End-to-end CLI test suite for Combine emulation, with two extra features:
#
#   VERBOSE=1  — print every full CLI response for visual inspection
#   (default)  — print a deduplicated list of every CLI command called at the
#                end of the run
#
# Sections 1–81  – general service coverage (S3, EC2, RDS, KMS, Lambda, …)
# Section  82    – EKS rewriter/filter verification (response + request paths)
#
# Usage examples:
#   ./cli-test-suite.sh                                                             # default: run all tests, print summary of commands at end
#   VERBOSE=1 ./cli-test-suite.sh                                                   # print every CLI response verbatim as it's received (for debugging/inspection)
#   EKS_REGION=us-iso-east-1 ./cli-test-suite.sh                                    # run only the EKS section (82), pointed at the specified cluster (must be configured to route through Combine)
#   VERBOSE=1 EKS_REGION=us-iso-east-1 EKS_CLUSTER=my-cluster ./cli-test-suite.sh   # run only the EKS section, print every CLI response

# This is a counterpart to the terraform test suite, and is necessary beacuse
# terraform and the CLI often request different default parameters and return
# formats.
#############################

set -uo pipefail

LOGFILE="validate_results.log"
touch $LOGFILE

function log() {
  echo -e "$1" | tee -a $LOGFILE
}

# NOTE: Mirrors the manual checklist's recommended ~/.aws/config (no client-side parameter validation, no retries) in a
# temporary copy, so the user's own config is never modified. S3 addressing style changes also land in this copy.
CLI_CONFIG_FILE=$(mktemp)
[[ -f "${AWS_CONFIG_FILE:-$HOME/.aws/config}" ]] && cp "${AWS_CONFIG_FILE:-$HOME/.aws/config}" "$CLI_CONFIG_FILE"
export AWS_CONFIG_FILE="$CLI_CONFIG_FILE"
aws configure set default.parameter_validation false
aws configure set default.max_attempts 1
aws configure set default.cli_pager ""

#############################
# Terraform-managed resources
#
# combine-test-setup.sh exports each Terraform output as TF_<OUTPUT_NAME>. Tests that need one of these
# resources are skipped (not failed) when it is missing, e.g. because the Terraform apply failed.
# Running locally without Terraform: export the variables yourself, or let those tests skip.
#############################

export TF_DYNAMODB_TABLE_NAME="${TF_DYNAMODB_TABLE_NAME:-}"
export TF_KINESIS_STREAM_NAME="${TF_KINESIS_STREAM_NAME:-}"
export TF_LAMBDA_FUNCTION_NAME="${TF_LAMBDA_FUNCTION_NAME:-}"
export TF_LAMBDA_FUNCTION_ARN="${TF_LAMBDA_FUNCTION_ARN:-}"
export TF_RDS_SUBNET_GROUP_NAME="${TF_RDS_SUBNET_GROUP_NAME:-}"
export TF_S3_BUCKET_PERMISSIONS="${TF_S3_BUCKET_PERMISSIONS:-}"
export TF_S3_BUCKET_CLOUDTRAIL="${TF_S3_BUCKET_CLOUDTRAIL:-}"
export TF_KMS_KEY_ARN="${TF_KMS_KEY_ARN:-}"
export TF_SNS_TOPIC_2_ARN="${TF_SNS_TOPIC_2_ARN:-}"
export TF_GLACIER_VAULT_NAME="${TF_GLACIER_VAULT_NAME:-}"
export TF_IAM_ROLE_ARN="${TF_IAM_ROLE_ARN:-}"
export TF_IAM_ROLE_CW_EVENTS_ARN="${TF_IAM_ROLE_CW_EVENTS_ARN:-}"
export TF_CLOUDWATCH_LOG_GROUP_ARN="${TF_CLOUDWATCH_LOG_GROUP_ARN:-}"
export TF_CLOUDWATCH_ALARM_NAME="${TF_CLOUDWATCH_ALARM_NAME:-}"
export TF_SQS_REDRIVE_QUEUE_URL="${TF_SQS_REDRIVE_QUEUE_URL:-}"
export TF_CLI_NETWORK_SECURITY_GROUP_ID="${TF_CLI_NETWORK_SECURITY_GROUP_ID:-}"

# Bucket the S3 tests read and write (the manual checklist used a pre-created "combine-endpoint-test" bucket).
export S3_TEST_BUCKET="$TF_S3_BUCKET_PERMISSIONS"

# Suffix for resources this suite creates itself, so concurrent or leftover runs do not collide.
RUN_SUFFIX="${TF_RUN_SUFFIX:--cli-$(date +%s)}"

# Combine shard under test (master | dev), used for shard-specific names such as Combine-<Shard>-TS-WLDEVELOPER.
case "${COMBINE_TEST_ENVIRONMENT:-dev}" in
  [Mm]aster|MASTER) SHARD="Master" ;;
  *) SHARD="Dev" ;;
esac

# ISO-B (us-isob-east-1) is no longer emulated; set ISOB_ENABLED=1 to run those tests against a shard that emulates it.
ISOB_ENABLED="${ISOB_ENABLED:-0}"

# Slow resource lifecycles (RDS, ElastiCache and MSK clusters, 500 MB S3 transfers). Set LONG_TESTS=false for quicker debugging runs.
LONG_TESTS="${LONG_TESTS:-true}"

# NOTE: Defaults to the Master VPC so local runs keep working; the workflow supplies the environment's VPC.
export VPC_ID="${TF_VPC_ID:-vpc-01e95d9106c2c1ef6}"
# One Combine Customer Subnet per Availability Zone, for tests that need subnets in different AZs.
mapfile -t TEST_SUBNETS < <(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:combine-id,Values=Combine-Customer-Subnet" --query 'Subnets[].[AvailabilityZone,SubnetId]' --output text 2>/dev/null | sort -u -k1,1 | awk '{print $2}')
SUBNET_1="${TEST_SUBNETS[0]:-}" SUBNET_2="${TEST_SUBNETS[1]:-}" SUBNET_3="${TEST_SUBNETS[2]:-}"
[[ -z "$SUBNET_1" ]] && SUBNET_1=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)
ENDPOINT_LOG_GROUP=$(aws logs describe-log-groups --log-group-name-prefix "Combine_${SHARD}_" --query "logGroups[?contains(logGroupName, 'Endpoint')].logGroupName | [0]" --output text 2>/dev/null || true)
UNSUPPORTED_INSTANCE_TYPE="db.r7i.large"
UNSUPPORTED_EMR_TYPE_1="m7i.xlarge"
UNSUPPORTED_EMR_TYPE_2="m7i.2xlarge"

# EKS section config — set EKS_REGION to enable section 82
EKS_REGION="${EKS_REGION:-}"
EKS_CLUSTER="${EKS_CLUSTER:-combine-master-eks}"

# Verbose mode — set VERBOSE=1 to print full CLI responses
VERBOSE="${VERBOSE:-0}"

# Tracks every CLI command issued during the run; printed as a summary at the end
COMMANDS_RUN=()

# Captured variables — initialized so set -u never fires if a preceding test fails
TRAIL_ARN="" UPLOAD_ID="" DDB_BACKUP_ARN="" STREAM_ARN="" SHARD_ID=""
SHARD_ITERATOR_ID="" NEXT_SHARD_ITERATOR_ID="" SUBNET_ID_1="" SUBNET_ID_2=""
VOLUME_ID="" TF_KINESIS_ARN="" KEY_ID="" GRANT_ID="" ENCRYPTED_BLOB=""
CODE_SIGNING_ARN="" SNS_TOPIC_ARN="" SUBSCRIPTION_ARN="" FS_ID=""
TEST_QUEUE_URL="" EC2_INSTANCE_ID=""

# record_cmd <cmd-string>: append a command to the tracking list
record_cmd() {
  COMMANDS_RUN+=("$1")
}

# Test result counters
PASS=0; FAIL=0; SKIP=0
FAILURES=()

record_pass() { PASS=$((PASS+1)); }
record_skip() { SKIP=$((SKIP+1)); }
record_fail() {
  local label="$1"
  local hint="${2:-}"
  FAIL=$((FAIL+1))
  FAILURES+=("${label}${hint:+ — ${hint}}")
}

# NOTE: Failed AWS calls report their reason on stderr; keep it so "empty or invalid response" failures say why.
CMD_STDERR=$(mktemp)
trap 'rm -f "$CMD_STDERR" "$CLI_CONFIG_FILE"' EXIT
print_cmd_stderr() { [[ -s "$CMD_STDERR" ]] && sed 's/^/   /' "$CMD_STDERR" | head -n 5; return 0; }

# require_tf <label> <VAR>...: returns 0 if every Terraform variable is set, otherwise reports the test as skipped.
# Usage: require_tf "my test" TF_FOO && validate_success "my test" "aws ... \$TF_FOO"
require_tf() {
  local label="$1"; shift
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      echo "🔍 ${label}: ⏭️ Skipped (Terraform resource unavailable: ${var})"
      record_skip
      return 1
    fi
  done
  return 0
}

# wait_rds_deleted <instance|cluster> <identifier>: not a test. Blocks until a database this suite created in the
# Terraform DB Subnet Group is gone, otherwise the Terraform destroy of that Subnet Group fails while it is still deleting.
wait_rds_deleted() {
  local kind="$1"
  local id="$2"
  local status

  if [[ "$kind" == "instance" ]]; then
    status=$(aws rds describe-db-instances --db-instance-identifier "$id" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null) || return 0
  else
    status=$(aws rds describe-db-clusters --db-cluster-identifier "$id" --query 'DBClusters[0].Status' --output text 2>/dev/null) || return 0
  fi

  if [[ "$status" != "deleting" ]]; then
    log "⚠️  RDS $kind $id is '$status', not deleting — Terraform cleanup of its Subnet Group may need a later sweep"
    return 0
  fi

  log "⏳ Waiting for RDS $kind $id to finish deleting..."
  aws rds wait "db-${kind}-deleted" "--db-${kind}-identifier" "$id" 2>/dev/null || log "⚠️  Timed out waiting for RDS $kind $id to delete"
}

# require_value <label> <VAR>: returns 0 if a value captured by an earlier test is set, otherwise skips the test.
require_value() {
  [[ -n "${!2:-}" && "${!2:-}" != "null" ]] && return 0
  echo "🔍 $1: ⏭️ Skipped (depends on a failed earlier step: $2 not captured)"
  record_skip
  return 1
}

# require_isob <label>: returns 0 when ISO-B tests are enabled, otherwise reports the test as skipped.
require_isob() {
  [[ "$ISOB_ENABLED" == "1" ]] && return 0
  echo "🔍 $1: ⏭️ Skipped (ISO-B emulation disabled; set ISOB_ENABLED=1)"
  record_skip
  return 1
}

# require_long <label>: returns 0 when long tests are enabled, otherwise reports the test as skipped.
require_long() {
  [[ "$LONG_TESTS" == "true" ]] && return 0
  echo "🔍 $1: ⏭️ Skipped (long test; set LONG_TESTS=true)"
  record_skip
  return 1
}

# validate_not_rejected <label> <command>: passes unless Combine rejects the call. For "should pass validation" checks
# where AWS itself may still refuse the call (e.g. because a resource is not ready).
validate_not_rejected() {
  local label="$1"
  local command="$2"
  local output

  printf "🔍 %s: " "$label"
  record_cmd "$command"
  output=$(eval "$command" 2>&1)

  if echo "$output" | grep -q "Combine rejected"; then
    echo "❌ Failed (rejected by Combine)"
    record_fail "$label" "Combine rejected a request that should pass its validation"
    echo "$output" | head -n 5
  else
    echo "✅ Passed (not rejected by Combine)"
    record_pass
  fi
}

# set_s3_addressing_style <path|auto>: not a test. Only changes this run's temporary CLI config.
set_s3_addressing_style() {
  record_cmd "aws configure set default.s3.addressing_style $1"
  aws configure set default.s3.addressing_style "$1"
}

# wait_until <timeout-seconds> <condition>: not a test. Polls the condition every 20 seconds until it succeeds.
wait_until() {
  local deadline=$((SECONDS + $1))
  until eval "$2" >/dev/null 2>&1; do
    (( SECONDS >= deadline )) && return 1
    sleep 20
  done
}

#############################
# FILE SETUP
#############################
log "📁 Preparing test files..."

echo "Foo Bar Baz" > test_cli_upload.txt
echo "How is your monkey's uncle?" > test_cli_presign_upload.txt
echo 'Wild monkey attack!!!' > test.encrypt

# S3 Notification Config JSON
cat > s3_bucket_notification.json <<EOF
{
  "TopicConfigurations": [
    {
      "Id": "Test1",
      "TopicArn": "arn:aws-iso:sns:us-iso-east-1:663117128738:FooTest",
      "Events": ["s3:ObjectCreated:Put"]
    },
    {
      "Id": "Test2",
      "TopicArn": "arn:aws-iso:sns:us-iso-east-1:663117128738:FooTest",
      "Events": ["s3:ObjectRestore:Delete", "s3:ObjectAcl:Put", "s3:ObjectTagging:Put", "s3:ObjectTagging:Delete", "s3:LifecycleTransition", "s3:LifecycleExpiration:Delete", "s3:LifecycleExpiration:DeleteMarkerCreated", "s3:IntelligentTiering"]
    }
  ],
  "QueueConfigurations": [
    {
      "Id": "Test1",
      "QueueArn": "arn:aws-iso:sqs:us-iso-east-1:663117128738:combine-endpoints-test",
      "Events": ["s3:ObjectCreated:Put"]
    }
  ]
}
EOF

# S3 Notification Config JSON (VALID but should still fail due to destination validation)
cat > s3_bucket_notification_valid.json <<EOF
{
  "TopicConfigurations": [
    {
      "Id": "Test1",
      "TopicArn": "arn:aws-iso:sns:us-iso-east-1:663117128738:FooTest",
      "Events": ["s3:ObjectCreated:Put"]
    }
  ]
}
EOF

cat > cloudtrail_event_selector_invalid_s3.json <<EOF
[
  {
    "ReadWriteType": "All",
    "IncludeManagementEvents": true,
    "DataResources": [
      {
        "Type": "AWS::S3::Object",
        "Values": ["arn:aws:s3"]
      },
      {
        "Type": "AWS::Lambda::Function",
        "Values": ["arn:aws-iso:lambda"]
      }
    ]
  }
]
EOF

cat > cloudtrail_event_selector_invalid_lambda.json <<EOF
[
  {
    "ReadWriteType": "All",
    "IncludeManagementEvents": true,
    "DataResources": [
      {
        "Type": "AWS::S3::Object",
        "Values": ["arn:aws-iso:s3"]
      },
      {
        "Type": "AWS::Lambda::Function",
        "Values": ["arn:aws-iso:lambda:us-east-1"]
      }
    ]
  }
]
EOF

cat > cloudtrail_event_selector_valid.json <<EOF
[
  {
    "ReadWriteType": "All",
    "IncludeManagementEvents": true,
    "DataResources": [
      {
        "Type": "AWS::S3::Object",
        "Values": ["arn:aws-iso:s3"]
      },
      {
        "Type": "AWS::Lambda::Function",
        "Values": ["arn:aws-iso:lambda"]
      }
    ]
  }
]
EOF

cat > glacier_job.json <<EOF
{
  "Type": "archive-retrieval",
  "ArchiveId": "kKB7ymWJVpPSwhGP6ycSOAekp9ZYe_--zM_mw6k76ZFGEIWQX-ybtRDvc2VkPSDtfKmQrj0IRQLSGsNuDp-AJVlu2ccmDSyDUmZwKbwbpAdGATGDiB3hHO0bjbGehXTcApVud_wyDw",
  "Description": "CombineTest",
  "SNSTopic": "arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest"
}
EOF

cat > test_queue.json <<EOF
{
  "Policy" : "{ \"Statement\" : [ { \"Action\" : \"SQS:SendMessage\", \"Effect\" : \"Allow\", \"Sid\": \"AllowPESends\", \"Principal\" : { \"AWS\" : \"*\" }, \"Condition\" : { \"ArnEquals\" : { \"aws:SourceArn\" : \"arn:aws-iso:sns:us-iso-east-1:193220141526:foo\" } }, \"Resource\" : \"arn:aws-iso:sqs:us-iso-east-1:663117128738:Test\" } ], \"Id\" : \"SQSPESendPolicy\", \"Version\" : \"2012-10-17\" }",
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"arn:aws-iso:sqs:us-iso-east-1:663117128738:TestRedrive\",\"maxReceiveCount\":\"1000\"}"
}
EOF

cat > test_queue_isob.json <<EOF
{
"Policy" : "{ \"Statement\" : [ { \"Action\" : \"SQS:SendMessage\", \"Effect\" : \"Allow\", \"Sid\": \"AllowPESends\", \"Principal\" : { \"AWS\" : \"*\" }, \"Condition\" : { \"ArnEquals\" : { \"aws:SourceArn\" : \"arn:aws-iso-b:sns:us-isob-east-1:193220141526:foo\" } }, \"Resource\" : \"arn:aws-iso-b:sqs:us-isob-east-1:663117128738:Test\" } ], \"Id\" : \"SQSPESendPolicy\", \"Version\" : \"2012-10-17\" }",
"RedrivePolicy": "{\"deadLetterTargetArn\":\"arn:aws-iso-b:sqs:us-isob-east-1:663117128738:TestRedrive\",\"maxReceiveCount\":\"1000\"}"
}
EOF

cat > events.json <<EOF
[
  {
    "Source": "com.mycompany.myapp",
    "Detail": "{ \"foo\": \"foo\", \"fooUser\": \"arn:aws-iso:iam::663117128738:user/master\" }",
    "Resources": [
      "arn:aws-iso:lambda:us-iso-east-1:663117128738:function:CombineTest",
      "arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest"
    ],
    "DetailType": "Foo"
  },
  {
    "Source": "com.mycompany.myapp",
    "Detail": "{ \"bar\": \"bar\", \"barRegion\": \"us-iso-east-1\" }",
    "Resources": [
      "arn:aws-iso:lambda:us-iso-east-1:663117128738:function:CombineTest",
      "arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest"
    ],
    "DetailType": "Bar"
  }
]
EOF

cat > test_sns.json <<EOF
{
  "Policy": "{\"Version\":\"2008-10-17\",\"Id\":\"__default_policy_ID\",\"Statement\":[{\"Sid\":\"__default_statement_ID\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"*\"},\"Action\":[\"SNS:GetTopicAttributes\",\"SNS:SetTopicAttributes\",\"SNS:AddPermission\",\"SNS:RemovePermission\",\"SNS:DeleteTopic\",\"SNS:Subscribe\",\"SNS:ListSubscriptionsByTopic\",\"SNS:Publish\"],\"Resource\":\"arn:aws-iso:sns:us-iso-east-1:663117128738:Test\",\"Condition\":{\"StringEquals\":{\"AWS:SourceOwner\":\"663117128738\"}}}]}",
  "KmsMasterKeyId": "${TF_KMS_KEY_ARN:-arn:aws-iso:kms:us-iso-east-1:663117128738:key/1c420142-fcc7-492a-a5b7-892bb3764ab7}"
}
EOF

echo '{
  "Id": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:ClientMount"
      ],
      "Principal": {
        "AWS": "arn:aws-iso:iam::663117128738:root"
      }
    }
  ]
}' > efs-policy.json

###########################################
## EKS helpers (used only in section 82) ##
###########################################

EKS_PASS=0; EKS_FAIL=0; EKS_SKIP=0
eks_ok()   { echo "  PASS: $1"; EKS_PASS=$((EKS_PASS+1)); }
eks_bad()  { echo "  FAIL: $1"; EKS_FAIL=$((EKS_FAIL+1)); }
eks_skip() { echo "  SKIP: $1"; EKS_SKIP=$((EKS_SKIP+1)); }
eks_note() { echo "  NOTE: $1"; }

# run: print the command, execute it, stream stdout+stderr to the terminal,
# stash stdout in RUN_OUT and exit code in RUN_RC for the caller to inspect.
eks_run() {
  echo "+ $*"
  local errfile; errfile="$(mktemp)"
  RUN_OUT="$("$@" 2>"$errfile")"; RUN_RC=$?
  [[ -n "$RUN_OUT" ]] && printf '%s\n' "$RUN_OUT"
  [[ -s "$errfile" ]] && sed 's/^/  | stderr: /' "$errfile"
  rm -f "$errfile"
  return $RUN_RC
}

# check: assert a value is present, carries the emulated region, and (for ARNs)
# the emulated partition. $1=label $2=value $3=arn|arn-global
eks_check() {
  local label="$1" val="$2" kind="$3"
  if [[ -z "$val" || "$val" == "null" ]]; then eks_skip "$label (absent on this cluster)"; return; fi
  echo "    $label = $val"
  if [[ "$kind" == "arn" ]]; then
    if [[ "$val" == arn:${EKS_EXP_PARTITION}:* ]]; then eks_ok "$label partition rewritten -> $EKS_EXP_PARTITION";
    else eks_bad "$label partition NOT rewritten (expected arn:$EKS_EXP_PARTITION:..)"; fi
  fi
  if [[ "$val" == *"$EKS_REGION"* ]]; then eks_ok "$label carries emulated region $EKS_REGION";
  elif [[ "$kind" == "arn-global" ]]; then eks_ok "$label is global (no region segment) — OK";
  else eks_bad "$label does NOT carry emulated region $EKS_REGION"; fi
}

# expect_reject_eks: assert a command is rejected (non-zero exit). $1=label $2..=command
expect_reject_eks() {
  local label="$1"; shift
  if eks_run "$@"; then eks_bad "$label was NOT rejected"; else eks_ok "$label rejected as expected"; fi
}

log "🧪 Starting validation test suite..."

###########################################
## Validate arns, iso values             ##
###########################################

validate_rewrite_smart() {
  local label="$1"
  local cmd="$2"
  local region="${3:-}"
  local jq_filter="${4:-}"
  local env_var_name="${5:-}"
  local pattern="arn:aws-iso(-b)?:|us-iso(-b)?|usie[0-9]?|usiw[0-9]?|usib[0-9]?|c2s.ic.gov|sc2s.sgov.gov|gov\.ic\.c2s\.us-iso-east-1|gov\.sgov\.sc2s\.us-isob-east-1|com\.amazonaws\.us-iso(-b)?-east-1\.s3"

  printf "🔍 %s%s: " "$label" "${region:+ ($region)}"

  local full_cmd="$cmd"
  [[ -n "$region" ]] && full_cmd="$cmd --region $region"

  record_cmd "$full_cmd"

  local output
  output=$(eval "$full_cmd" 2>"$CMD_STDERR")

  if [[ -z "$output" || "$output" == "null" ]]; then
    echo "❌ Failed (empty or invalid response)"
    print_cmd_stderr
    record_fail "$label${region:+ ($region)}" "command returned empty/invalid — check credentials or endpoint"
    return 1
  fi

  [[ "$VERBOSE" == "1" ]] && echo "" && echo "$output" | jq . 2>/dev/null || true

  local matches
  matches=$(echo "$output" | jq -r '.. | scalars | select(type == "string")' | grep -E "$pattern" || true)

  if [[ -n "$matches" ]]; then
    echo "✅ Passed"
    record_pass

    # Optional variable extraction
    if [[ -n "$jq_filter" && -n "$env_var_name" ]]; then
      local value
      value=$(echo "$output" | jq -r "$jq_filter" 2>/dev/null)
      if [[ -n "$value" && "$value" != "null" ]]; then
        export "$env_var_name=$value"
        log "🧬 Captured $env_var_name=$value"
      else
        log "⚠️  Warning: $label - could not extract $env_var_name using $jq_filter"
      fi
    fi

  else
    echo "❌ Failed (no rewritten strings found)"
    record_fail "$label${region:+ ($region)}" "response returned but no ISO ARNs/regions detected — check rewriter"
    echo "$output" | jq . | head -n 20
    return 1
  fi
}
###########################################
## Validate if the result is blocked     ##
###########################################

validate_expected_error_match() {
  local label="$1"
  local command="$2"
  local expected_message="$3"
  local fallback_message="${4:-}"

  printf "🚫 %s: " "$label"

  record_cmd "$command"

  local output
  output=$(eval "$command" 2>&1)

  [[ "$VERBOSE" == "1" ]] && echo "" && echo "$output"

  if echo "$output" | grep -q "$expected_message"; then
    echo "✅ Passed ($expected_message)"
    record_pass
  else
    if echo "$output" | grep -q "403"; then
      echo "❌ Failed (403 - possible encoding bug)"
      record_fail "$label" "got 403 — possible URI encoding bug in proxy"
    else
      echo "❌ Failed${fallback_message:+ ($fallback_message)}"
      record_fail "$label" "expected error not found${fallback_message:+ — $fallback_message}"
    fi
    echo "$output" | head -n 10
  fi
}

###########################################
## Validate that value is missing        ##
###########################################

validate_instance_type_absent_grep() {
  local label="$1"
  local command="$2"
  local forbidden="$3"

  printf "🔍 %s: " "$label"

  record_cmd "$command"

  local output
  output=$(eval "$command" 2>/dev/null)

  [[ "$VERBOSE" == "1" ]] && echo "" && echo "$output" | jq . 2>/dev/null || true

  if echo "$output" | grep -q "$forbidden"; then
    echo "❌ Failed (found forbidden instance type: $forbidden)"
    record_fail "$label" "forbidden instance type '$forbidden' was not filtered — check type filter config"
    echo "$output" | grep "$forbidden"
  else
    echo "✅ Passed (no $forbidden found)"
    record_pass
  fi
}

###########################################
## Validate that value is missing        ##
###########################################

validate_rewrite_with_exception() {
  local label="$1"
  local cmd="$2"
  local exception_pattern="$3"
  local pattern="arn:aws-iso(-b)?:|us-iso(-b)?|usie[0-9]?|usiw[0-9]?|usib[0-9]?|c2s.ic.gov|sc2s.sgov.gov|gov\.ic\.c2s\.us-iso-east-1|gov\.sgov\.sc2s\.us-isob-east-1|com\.amazonaws\.us-iso(-b)?-east-1\.s3"

  printf "🔍 %s: " "$label"

  record_cmd "$cmd"

  local output
  output=$(eval "$cmd" 2>"$CMD_STDERR")

  if [[ -z "$output" || "$output" == "null" ]]; then
    echo "❌ Failed (empty or invalid response)"
    print_cmd_stderr
    record_fail "$label" "command returned empty/invalid — check credentials or endpoint"
    return 1
  fi

  [[ "$VERBOSE" == "1" ]] && echo "" && echo "$output" | jq . 2>/dev/null || true

  local matches
  matches=$(echo "$output" | jq -r '.. | scalars | select(type == "string")' | grep -E "$pattern" || true)

  if [[ -n "$matches" ]]; then
    if echo "$matches" | grep -F "$exception_pattern" > /dev/null; then
      echo "❌ Failed (unexpected rewrite of exception: $exception_pattern)"
      record_fail "$label" "exception pattern '$exception_pattern' was unexpectedly rewritten — check rewriter exclusions"
      echo "$matches" | grep -F "$exception_pattern" | head -n 10
      return 1
    fi
    echo "✅ Passed"
    record_pass
  else
    echo "❌ Failed (no rewritten strings found)"
    record_fail "$label" "response returned but no ISO ARNs/regions detected — check rewriter"
    echo "$output" | jq . | head -n 20
    return 1
  fi
}

###########################################
## Validate unsupported operation        ##
###########################################
#validate_unsupported_operation() {
#  local label="$1"
#  local command="$2"
#
#  printf "🔍 %s: " "$label"
#
#  output=$(eval "$command" 2>&1 || true)
#
#  if echo "$output" | grep -q "An error occurred (UnsupportedOperation)"; then
#    echo "✅ Passed (UnsupportedOperation as expected)"
#  else
#    echo "❌ Failed (Did not return UnsupportedOperation)"
#    echo "$output" | head -n 2
#  fi
#}
## this function is used when we need to check if the call passed and it returns a result that doesnt need to be rewritten
###########################################
## Validate if no error                  ##
###########################################

validate_success() {
  local label="$1"
  local command="$2"
  local expected="${3:-}"  # optional third arg

  printf "🔍 %s: " "$label"

  record_cmd "$command"

  local output
  if output=$(eval "$command" 2>&1); then
    [[ "$VERBOSE" == "1" ]] && echo "" && echo "$output"
    if [[ "$expected" == "__nonempty__" ]]; then
      if [[ -n "$output" && "$output" != "null" ]]; then
        echo "✅ Passed"
        record_pass
      else
        echo "❌ Failed (empty or null output)"
        record_fail "$label" "command succeeded but returned empty output"
      fi
    elif [[ -n "$expected" ]]; then
      if [[ "$output" == *"$expected"* ]]; then
        echo "✅ Passed"
        record_pass
      else
        echo "❌ Failed (expected string not found)"
        record_fail "$label" "command succeeded but expected '$expected' not found in output"
        echo "   🔸 Expected: $expected"
        echo "   🔸 Output: $output" | head -n 10
      fi
    else
      echo "✅ Passed"
      record_pass
    fi
  else
    [[ "$VERBOSE" == "1" ]] && echo "" && echo "$output"
    echo "❌ Failed"
    record_fail "$label" "command returned non-zero exit code — check output above"
    echo "$output" | head -n 10
  fi
}

#Maybe I can find a way to consolidate some of these functions? maybe add a flag that contians what value I'm expecting to see and send that for comparison.'
###########################################
## Validate expected errors              ##
###########################################

#validate_expected_error_match() {
#  local label="$1"
#  local cmd="$2"
#  local expected_code="$3"
#
#  echo -n "🔍 $label: "
#
#  local output
#  output=$(eval "$cmd" 2>&1)
#
#  if echo "$output" | grep -q "$expected_code"; then
#    echo "✅ Passed"
#  elif echo "$output" | grep -q "403"; then
#    echo "❌ Failed (returned 403, possible URI encoding bug)"
#    echo "$output"
#  else
#    echo "❌ Failed (unexpected error)"
#    echo "$output"
#  fi
#}

###########################################
## Validate S3 still works               ##
###########################################

validate_s3() {
  local label="$1"
  local source="$2"
  local s3_key="$3"
  local mode="$4"
  local bucket="$S3_TEST_BUCKET"
  local s3_uri="s3://$bucket/$s3_key"
  local back_file="${source}_back"

  if [[ -z "$bucket" ]]; then
    echo "🔍 ${label}: ⏭️ Skipped (Terraform resource unavailable: TF_S3_BUCKET_PERMISSIONS)"
    record_skip
    return
  fi

  printf "🔍 %s: " "$label"

  if [[ "$mode" == "basic" ]]; then
    record_cmd "$source"
    local output
    if output=$(eval "$source" 2>/dev/null) && [[ "$output" != "null" && -n "$output" ]]; then
      [[ "$VERBOSE" == "1" ]] && echo "" && echo "$output" | jq . 2>/dev/null || true
      echo "✅ Passed"
      record_pass
    else
      echo "❌ Failed (null or error)"
      record_fail "$label" "S3 basic operation failed — check bucket access and credentials"
    fi

  elif [[ "$mode" == "checksum" || "$mode" == "presign" ]]; then
    # Auto-generate test file if it doesn't exist
    if [[ ! -f "$source" ]]; then
      case "$source" in
        smallfile.txt) head -c 500 < /dev/urandom | base64 > "$source" ;;
        file.txt) head -c 50000 < /dev/urandom | base64 > "$source" ;;
        bigfile.txt) head -c 5000000 < /dev/urandom | base64 > "$source" ;;
        megafile.txt) head -c 500000000 < /dev/urandom | base64 > "$source" ;;
        *) echo "❌ Unknown file: $source"; record_fail "$label" "unknown source file '$source'"; return ;;
      esac
    fi

    # Upload to S3
    record_cmd "aws s3 cp $source $s3_uri"
    local upload_out
    if ! upload_out=$(aws s3 cp "$source" "$s3_uri" 2>&1); then
      echo "❌ Upload failed"
      record_fail "$label" "upload to S3 failed — check bucket write access and credentials"
      [[ "$VERBOSE" == "1" ]] && echo "$upload_out"
      return
    fi
    [[ "$VERBOSE" == "1" ]] && echo "" && echo "$upload_out"

    # Download from S3 using wget and presigned URL (for presign mode)
    if [[ "$mode" == "presign" ]]; then
      record_cmd "aws s3 presign $s3_uri"
      local url
      url=$(aws s3 presign "$s3_uri")
      [[ "$VERBOSE" == "1" ]] && echo "" && echo "Presigned URL: $url"
      record_cmd "wget <presigned-url> -O $back_file --no-check-certificate"
      if ! wget "$url" -O "$back_file" --no-check-certificate > /dev/null 2>&1; then
        echo "❌ Download (presign) failed"
        record_fail "$label" "presigned URL download failed — check presign endpoint or URL encoding"
        return
      fi
    else
      record_cmd "aws s3 cp $s3_uri $back_file"
      local dl_out
      if ! dl_out=$(aws s3 cp "$s3_uri" "$back_file" 2>&1); then
        echo "❌ Download failed"
        record_fail "$label" "download from S3 failed — check bucket read access"
        [[ "$VERBOSE" == "1" ]] && echo "$dl_out"
        return
      fi
      [[ "$VERBOSE" == "1" ]] && echo "" && echo "$dl_out"
    fi

    # Compare checksums
    local orig_sum back_sum
    orig_sum=$(md5sum "$source" | awk '{print $1}')
    back_sum=$(md5sum "$back_file" | awk '{print $1}')

    if [[ "$orig_sum" == "$back_sum" ]]; then
      echo "✅ Passed"
      record_pass
    else
      echo "❌ Checksum mismatch"
      record_fail "$label" "MD5 mismatch after upload/download — possible data corruption or partial transfer"
      echo "   🔸 Original:   $orig_sum"
      echo "   🔸 Downloaded: $back_sum"
    fi

    # NOTE: Presign downloads are kept for the content check that follows them (section 35).
    [[ "$mode" == "presign" ]] || rm -f "$back_file"

  else
    echo "❌ Unknown mode: $mode"
    record_fail "$label" "unknown mode '$mode'"
  fi
}

log ""
log "########################"
log "# 1. Calls should pass, will check rewritten values"
log "########################"

validate_rewrite_smart "ec2 describe-regions" "aws ec2 describe-regions" ""
validate_rewrite_smart "ec2 describe-regions" "aws ec2 describe-regions" "us-iso-west-1"
require_isob "ec2 describe-regions" && validate_rewrite_smart "ec2 describe-regions" "aws ec2 describe-regions" "us-isob-east-1"

validate_rewrite_smart "ec2 describe-availability-zones" "aws ec2 describe-availability-zones" ""
validate_rewrite_smart "ec2 describe-availability-zones" "aws ec2 describe-availability-zones" "us-iso-west-1"
require_isob "ec2 describe-availability-zones" && validate_rewrite_smart "ec2 describe-availability-zones" "aws ec2 describe-availability-zones" "us-isob-east-1"

validate_rewrite_smart "ec2 describe-subnets" "aws ec2 describe-subnets" ""
validate_rewrite_smart "ec2 describe-subnets" "aws ec2 describe-subnets" "us-iso-west-1"
require_isob "ec2 describe-subnets" && validate_rewrite_smart "ec2 describe-subnets" "aws ec2 describe-subnets" "us-isob-east-1"

validate_expected_error_match "trustedadvisor list-checks" "aws trustedadvisor list-checks" "Combine rejected this AWS API"
require_isob "trustedadvisor list-checks (ISO-B)" && validate_expected_error_match "trustedadvisor list-checks (ISO-B)" "aws trustedadvisor list-checks --region us-isob-east-1" "Combine rejected this AWS API"

log ""
log "########################"
log "# 2. Expected 501 Failures"
log "########################"

validate_expected_error_match "autoscaling describe-traffic-sources" "aws autoscaling describe-traffic-sources --auto-scaling-group-name foo" "Combine rejected this AWS API"
validate_expected_error_match "cloudformation describe-stack-resource-drifts" "aws cloudformation describe-stack-resource-drifts --stack-name CombineTest" "Combine rejected this AWS API"
validate_expected_error_match "cloudtrail get-insight-selectors" "aws cloudtrail get-insight-selectors --trail-name CombineTest" "Combine rejected this AWS API"
validate_expected_error_match "cloudwatch describe-insight-rules" "aws cloudwatch describe-insight-rules" "Combine rejected this AWS API"
validate_expected_error_match "events list-archives" "aws events list-archives" "Combine rejected this AWS API"
validate_expected_error_match "deploy list-git-hub-account-token-names" "aws deploy list-git-hub-account-token-names" "Combine rejected this AWS API"
validate_expected_error_match "comprehend contains-pii-entities" "aws comprehend contains-pii-entities --text foo --language-code foo" "Combine rejected this AWS API"
validate_expected_error_match "configservice describe-conformance-packs" "aws configservice describe-conformance-packs" "Combine rejected this AWS API"
validate_expected_error_match "ds add-region" "aws ds add-region --directory-id foo --region-name us-iso-west-1 --vpc-settings {}" "Combine rejected this AWS API"
validate_expected_error_match "dynamodb describe-contributor-insights" "aws dynamodb describe-contributor-insights --table-name foo" "Combine rejected this AWS API"
validate_expected_error_match "ec2 describe-traffic-mirror-filters" "aws ec2 describe-traffic-mirror-filters" "Combine rejected this AWS API"
validate_expected_error_match "ec2 describe-spot-instance-requests" "aws ec2 describe-spot-instance-requests" "Combine rejected this AWS API"
validate_expected_error_match "ecr describe-image-scan-findings" "aws ecr describe-image-scan-findings --repository-name foo --image-id imageDigest=foo,imageTag=foo" "Combine rejected this AWS API"
validate_expected_error_match "ecs describe-capacity-providers" "aws ecs describe-capacity-providers" "Combine rejected this AWS API"
validate_expected_error_match "elasticache describe-global-replication-groups" "aws elasticache describe-global-replication-groups" "Combine rejected this AWS API"
validate_expected_error_match "elb create-app-cookie-stickiness-policy" "aws elb create-app-cookie-stickiness-policy --load-balancer-name foo --policy-name foo --cookie-name foo" "Combine rejected this AWS API"
validate_expected_error_match "eks describe-insight" "aws eks describe-insight --cluster-name foo --id foo" "Combine rejected this AWS API"
validate_expected_error_match "emr list-notebook-executions" "aws emr list-notebook-executions" "Combine rejected this AWS API"
validate_expected_error_match "glue list-workflows" "aws glue list-workflows" "Combine rejected this AWS API"
validate_expected_error_match "guardduty describe-malware-scans" "aws guardduty describe-malware-scans --detector-id foo" "Combine rejected this AWS API"
validate_expected_error_match "imagebuilder list-workflows" "aws imagebuilder list-workflows" "Combine rejected this AWS API"
validate_expected_error_match "kms create-custom-key-store" "aws kms create-custom-key-store --custom-key-store-name foo" "Combine rejected this AWS API"
validate_expected_error_match "lambda get-function-url-config" "aws lambda get-function-url-config --function-name foo" "Combine rejected this AWS API"
require_isob "license-manager get-grant" && validate_expected_error_match "license-manager get-grant" "aws license-manager get-grant --grant-arn foo --region us-isob-east-1" "Combine rejected this AWS API"
validate_expected_error_match "medialive list-multiplexes" "aws medialive list-multiplexes" "Combine rejected this AWS API"
validate_expected_error_match "rds describe-blue-green-deployments" "aws rds describe-blue-green-deployments" "Combine rejected this AWS API"
validate_expected_error_match "redshift copy-cluster-snapshot" "aws redshift copy-cluster-snapshot --source-snapshot-identifier foo --target-snapshot-identifier foo" "Combine rejected this AWS API"
validate_expected_error_match "route53 list-traffic-policies" "aws route53 list-traffic-policies" "Combine rejected this AWS API"
validate_expected_error_match "route53resolver list-resolver-query-log-configs" "aws route53resolver list-resolver-query-log-configs" "Combine rejected this AWS API"
validate_expected_error_match "sagemaker list-code-repositories" "aws sagemaker list-code-repositories" "Combine rejected this AWS API"
validate_expected_error_match "secretsmanager stop-replication-to-replica" "aws secretsmanager stop-replication-to-replica --secret-id foo" "Combine rejected this AWS API"
validate_expected_error_match "sns get-data-protection-policy" "aws sns get-data-protection-policy --resource-arn foo" "Combine rejected this AWS API"
validate_expected_error_match "stepfunctions test-state" "aws stepfunctions test-state --definition {} --role-arn foo" "Combine rejected this AWS API"
validate_expected_error_match "transcribe list-medical-vocabularies" "aws transcribe list-medical-vocabularies" "Combine rejected this AWS API"
require_isob "workspaces create-updated-workspace-image" && validate_expected_error_match "workspaces create-updated-workspace-image" "aws workspaces create-updated-workspace-image --name foo --description foo --source-image-id foo --region us-isob-east-1" "Combine rejected this AWS API"

log ""
log "########################"
log "# 3. Should return 501 Not Implemented (Unsupported services - implicitly denied)"
log "# These services are unsupported and should trigger Combine-style rejection"
log "########################"

validate_expected_error_match "polly list-lexicons" "aws polly list-lexicons" "Combine rejected this AWS API"
validate_expected_error_match "macie2 list-members" "aws macie2 list-members" "Combine rejected this AWS API"

log ""
log "########################"
log "# 4. (Does Not Exist)"
log "########################"

log ""
log "########################"
log "# 5. Instance Type Filtering"
log "# These should run but m7a.large must NOT be in the results"
log "########################"

validate_instance_type_absent_grep "instance-type-offerings (filtered)" "aws ec2 describe-instance-type-offerings --filters Name=instance-type,Values=m5.*,m7a.large" "m7a.large"
validate_instance_type_absent_grep "describe-instance-types (filtered)" "aws ec2 describe-instance-types --filters Name=instance-type,Values=m5.large,m7a.large" "m7a.large"
validate_instance_type_absent_grep "instance-type-offerings (raw)" "aws ec2 describe-instance-type-offerings" "m7a.large"
validate_instance_type_absent_grep "describe-instance-types (raw)" "aws ec2 describe-instance-types" "m7a.large"

log ""
log "########################"
log "# 6. ClassicLink Unsupported Operations"
log "# These should fail with UnsupportedOperation (400)"
log "########################"

validate_expected_error_match "describe-vpc-classic-link" "aws ec2 describe-vpc-classic-link" "UnsupportedOperation"
require_isob "describe-vpc-classic-link (ISOB)" && validate_expected_error_match "describe-vpc-classic-link (ISOB)" "aws ec2 describe-vpc-classic-link --region us-isob-east-1" "UnsupportedOperation"
validate_expected_error_match "describe-vpc-classic-link-dns-support" "aws ec2 describe-vpc-classic-link-dns-support" "UnsupportedOperation"
require_isob "describe-vpc-classic-link-dns-support (ISOB)" && validate_expected_error_match "describe-vpc-classic-link-dns-support (ISOB)" "aws ec2 describe-vpc-classic-link-dns-support --region us-isob-east-1" "UnsupportedOperation"

log ""
log "########################"
log "# 7. S3 Basic Validation"
log "########################"

validate_s3 "S3 list-buckets" "aws s3api list-buckets" "" "basic"
validate_s3 "S3 list-objects" "aws s3api list-objects --bucket $S3_TEST_BUCKET" "" "basic"

log ""
log "########################"
log "# 8. S3 Upload + Checksum"
log "########################"

validate_s3 "S3 smallfile.txt" "smallfile.txt" "foo/smallfile.txt" "checksum"
validate_s3 "S3 file.txt" "file.txt" "foo/file.txt" "checksum"
validate_s3 "S3 file++.txt" "file.txt" "foo/bar/baz/file++.txt" "checksum"
validate_s3 "S3 bigfile.txt" "bigfile.txt" "foo/bigfile.txt" "checksum"
require_long "S3 megafile.txt" && validate_s3 "S3 megafile.txt" "megafile.txt" "foo/megafile.txt" "checksum"

log ""
log "########################"
log "# 9. Validate S3 rewrite"
log "########################"

require_tf "s3api put-object (plain)" TF_S3_BUCKET_PERMISSIONS && validate_success "s3api put-object (plain)" "aws s3api put-object --bucket $S3_TEST_BUCKET --body ./test_cli_upload.txt --key test_cli_upload.txt"
require_tf "s3api put-object (KMS)" TF_S3_BUCKET_PERMISSIONS && validate_rewrite_smart "s3api put-object (KMS)" "aws s3api put-object --bucket $S3_TEST_BUCKET --body ./test_cli_upload.txt --key test_cli_upload_kms.txt --ssekms-key-id $TF_KMS_KEY_ARN --server-side-encryption aws:kms" ""
require_tf "s3api get-bucket-encryption" TF_S3_BUCKET_PERMISSIONS && validate_success "s3api get-bucket-encryption" "aws s3api get-bucket-encryption --bucket $S3_TEST_BUCKET"
require_tf "s3api put-bucket-inventory-configuration" TF_S3_BUCKET_PERMISSIONS && validate_success "s3api put-bucket-inventory-configuration" "aws s3api put-bucket-inventory-configuration --bucket $S3_TEST_BUCKET --id Test --inventory-configuration '{\"Destination\": { \"S3BucketDestination\": { \"AccountId\": \"663117128738\", \"Bucket\": \"arn:aws-iso:s3:::$S3_TEST_BUCKET\", \"Format\": \"CSV\" }}, \"IsEnabled\": true, \"Id\": \"Test\", \"IncludedObjectVersions\": \"Current\", \"Schedule\": { \"Frequency\": \"Daily\" }}'"
require_tf "s3api get-bucket-inventory-configuration" TF_S3_BUCKET_PERMISSIONS && validate_rewrite_smart "s3api get-bucket-inventory-configuration" "aws s3api get-bucket-inventory-configuration --bucket $S3_TEST_BUCKET --id Test" ""
require_tf "s3api list-bucket-inventory-configurations" TF_S3_BUCKET_PERMISSIONS && validate_rewrite_smart "s3api list-bucket-inventory-configurations" "aws s3api list-bucket-inventory-configurations --bucket $S3_TEST_BUCKET" ""
require_tf "s3api delete-bucket-inventory-configuration" TF_S3_BUCKET_PERMISSIONS && validate_success "s3api delete-bucket-inventory-configuration" "aws s3api delete-bucket-inventory-configuration --bucket $S3_TEST_BUCKET --id Test"
require_tf "s3api list-bucket-inventory-configurations (after delete)" TF_S3_BUCKET_PERMISSIONS && validate_success "s3api list-bucket-inventory-configurations (after delete)" "aws s3api list-bucket-inventory-configurations --bucket $S3_TEST_BUCKET"
require_tf "s3api head-bucket" TF_S3_BUCKET_PERMISSIONS && validate_rewrite_smart "s3api head-bucket" "aws s3api head-bucket --bucket $S3_TEST_BUCKET" ""

log ""
log "########################"
log "# 10. Validate Expected errors to render properly (API request flow not broken)"
log "########################"

validate_expected_error_match "stop-instances with invalid instance ID" "aws ec2 stop-instances --instance-ids i-0a9e2c2233951dee8" "InvalidInstanceID\.NotFound"
validate_expected_error_match "s3 cp to non-existent bucket" "aws s3 cp smallfile.txt s3://combine-endpoint-test-DNE/foo/smallfile.txt/" "NoSuchBucket"
validate_expected_error_match "describe-images with invalid AMI" "aws ec2 describe-images --image-ids ami-5731123e" "InvalidAMIID\.NotFound"

log ""
log "########################"
log "# 11. Validate non-normalized URL"
log "########################"
validate_rewrite_smart "sts get-caller-identity (non-normalized URL)" "aws sts get-caller-identity --endpoint-url https://sts.us-iso-east-1.c2s.ic.gov//" ""

log ""
log "########################"
log "# 12. Validate fail with NotFoundException (Testing double encoding of URI)"
log "########################"

validate_expected_error_match "eks tag-resource" "aws eks tag-resource --resource-arn arn:aws-iso:eks:us-iso-east-1:663117128738:cluster/demo --tags Test=Test" "NotFoundException"
validate_expected_error_match "eks untag-resource" "aws eks untag-resource --resource-arn arn:aws-iso:eks:us-iso-east-1:663117128738:cluster/demo --tag-keys Test" "NotFoundException"

log ""
log "########################"
log "# 13. Validate multipart upload rewritten"
log "########################"
## not sure how to condense this, cause I need to verify the create result but.. I also need to extract values from it to use in the other checks.. I'll circle back to this later LRM'
if require_tf "s3api multipart upload" TF_S3_BUCKET_PERMISSIONS; then
CREATE_CMD="aws s3api create-multipart-upload --bucket $S3_TEST_BUCKET --key foobarbaz"
record_cmd "$CREATE_CMD"
OUTPUT_CREATE=$(eval "$CREATE_CMD" 2>"$CMD_STDERR")

echo -n "🔍 s3api create-multipart-upload: "
# NOTE: The response has no ARN or region to rewrite; an UploadId means the call went through.
if [[ -n "$(echo "$OUTPUT_CREATE" | jq -r '.UploadId // empty' 2>/dev/null)" ]]; then
  echo "✅ Passed"
  record_pass
  [[ "$VERBOSE" == "1" ]] && echo "$OUTPUT_CREATE" | jq .
else
  echo "❌ Failed (no UploadId returned)"
  print_cmd_stderr
  record_fail "s3api create-multipart-upload" "no UploadId returned"
  echo "$OUTPUT_CREATE" | jq . | head -n 20
fi

# Extract UploadId
UPLOAD_ID=$(echo "$OUTPUT_CREATE" | jq -r '.UploadId')

# Continue using existing validate_rewrite_smart
require_tf "s3api list-multipart-uploads" TF_S3_BUCKET_PERMISSIONS && validate_rewrite_smart "s3api list-multipart-uploads" "aws s3api list-multipart-uploads --bucket $S3_TEST_BUCKET" ""
require_tf "s3api list-parts" TF_S3_BUCKET_PERMISSIONS && validate_rewrite_smart "s3api list-parts" "aws s3api list-parts --bucket $S3_TEST_BUCKET --key foobarbaz --upload-id $UPLOAD_ID" ""

# Clean up the multipart upload
ABORT_CMD="aws s3api abort-multipart-upload --bucket $S3_TEST_BUCKET --key foobarbaz --upload-id $UPLOAD_ID"
record_cmd "$ABORT_CMD"
eval "$ABORT_CMD" >/dev/null 2>&1
echo "🧹 Aborted multipart upload (UploadId: $UPLOAD_ID)"
fi

log ""
log "########################"
log "# 14. Validate 404 return, if 403 will throw error."
log "########################"

require_tf "s3 cp URI (foo++)" TF_S3_BUCKET_PERMISSIONS && validate_expected_error_match "s3 cp URI (foo++)" "aws s3 cp s3://$S3_TEST_BUCKET/foo/foo++.txt ." "404"
require_tf "s3 cp deep URI" TF_S3_BUCKET_PERMISSIONS && validate_expected_error_match "s3 cp deep URI" "aws s3 cp s3://$S3_TEST_BUCKET/foo/foo++//bar/baz///boz.txt ." "404"
require_tf "head-object foo/foo.txt" TF_S3_BUCKET_PERMISSIONS && validate_expected_error_match "head-object foo/foo.txt" "aws s3api head-object --bucket $S3_TEST_BUCKET --key foo/foo.txt" "404"
require_tf "head-object foo/foo++.txt" TF_S3_BUCKET_PERMISSIONS && validate_expected_error_match "head-object foo/foo++.txt" "aws s3api head-object --bucket $S3_TEST_BUCKET --key foo/foo++.txt" "404"
require_tf "head-object foo//foo++.txt" TF_S3_BUCKET_PERMISSIONS && validate_expected_error_match "head-object foo//foo++.txt" "aws s3api head-object --bucket $S3_TEST_BUCKET --key foo//foo++.txt" "404"

log ""
log "########################"
log "# 15. Validate Testing special characters in URI should pass"
log "########################"

require_tf "s3 cp upload (special chars)" TF_S3_BUCKET_PERMISSIONS && validate_success "s3 cp upload (special chars)" 'aws s3 cp smallfile.txt "s3://$S3_TEST_BUCKET/foo/bar++/baz/test and test+.txt"'
require_tf "s3 cp upload (nested //)" TF_S3_BUCKET_PERMISSIONS && validate_success "s3 cp upload (nested //)" 'aws s3 cp smallfile.txt "s3://$S3_TEST_BUCKET/foo/bar++/baz//boz//bix//test.txt"'
require_tf "s3 cp upload (deep nested ////)" TF_S3_BUCKET_PERMISSIONS && validate_success "s3 cp upload (deep nested ////)" 'aws s3 cp smallfile.txt "s3://$S3_TEST_BUCKET/foo/bar++/baz///boz//bix////test.txt"'

require_tf "s3 cp download (special chars)" TF_S3_BUCKET_PERMISSIONS && validate_success "s3 cp download (special chars)" 'aws s3 cp "s3://$S3_TEST_BUCKET/foo/bar++/baz/test and test+.txt" .'
require_tf "s3 cp download (nested //)" TF_S3_BUCKET_PERMISSIONS && validate_success "s3 cp download (nested //)" 'aws s3 cp "s3://$S3_TEST_BUCKET/foo/bar++/baz//boz//bix//test.txt" .'
require_tf "s3 cp download (deep nested ////)" TF_S3_BUCKET_PERMISSIONS && validate_success "s3 cp download (deep nested ////)" 'aws s3 cp "s3://$S3_TEST_BUCKET/foo/bar++/baz///boz//bix////test.txt" .'

require_tf "s3 cp test2.txt" TF_S3_BUCKET_PERMISSIONS && validate_success "s3 cp test2.txt" 'aws s3 cp smallfile.txt "s3://$S3_TEST_BUCKET/test2.txt"'
require_tf "s3 cp test3.txt" TF_S3_BUCKET_PERMISSIONS && validate_success "s3 cp test3.txt" 'aws s3 cp smallfile.txt "s3://$S3_TEST_BUCKET/foo/test3.txt"'

require_tf "head-object test2.txt" TF_S3_BUCKET_PERMISSIONS && validate_success "head-object test2.txt" 'aws s3api head-object --bucket $S3_TEST_BUCKET --key "test2.txt"'
require_tf "head-object test3.txt" TF_S3_BUCKET_PERMISSIONS && validate_success "head-object test3.txt" 'aws s3api head-object --bucket $S3_TEST_BUCKET --key "foo/test3.txt"'
require_tf "head-object test+.txt" TF_S3_BUCKET_PERMISSIONS && validate_success "head-object test+.txt" 'aws s3api head-object --bucket $S3_TEST_BUCKET --key "foo/bar++/baz/test and test+.txt"'
require_tf "head-object test.txt (nested)" TF_S3_BUCKET_PERMISSIONS && validate_success "head-object test.txt (nested)" 'aws s3api head-object --bucket $S3_TEST_BUCKET --key "foo/bar++/baz//boz//bix//test.txt"'
require_tf "head-object test.txt (deep nested)" TF_S3_BUCKET_PERMISSIONS && validate_success "head-object test.txt (deep nested)" 'aws s3api head-object --bucket $S3_TEST_BUCKET --key "foo/bar++/baz///boz//bix////test.txt"'


log ""
log "########################"
log "# 16. Validate it returns empty, the action is a violation but it should still not return anything"
log "########################"

require_tf "s3api get-bucket-accelerate-configuration" TF_S3_BUCKET_PERMISSIONS && validate_success "s3api get-bucket-accelerate-configuration" "aws s3api get-bucket-accelerate-configuration --bucket $S3_TEST_BUCKET"

log ""
log "########################"
log "# 17. Should fail with Unsupported Argument"
log "########################"

require_tf "s3api put-bucket-accelerate-configuration (should fail)" TF_S3_BUCKET_PERMISSIONS && validate_expected_error_match "s3api put-bucket-accelerate-configuration (should fail)" "aws s3api put-bucket-accelerate-configuration --bucket $S3_TEST_BUCKET --accelerate-configuration {}" "" "UnsupportedArgument"

log ""
log "########################"
log "# 18. Invalid notification events should fail"
log "########################"

require_tf "s3api put-bucket-notification-configuration (invalid events)" TF_S3_BUCKET_PERMISSIONS && validate_expected_error_match "s3api put-bucket-notification-configuration (invalid events)" "aws s3api put-bucket-notification-configuration --bucket $S3_TEST_BUCKET --notification-configuration file://s3_bucket_notification.json" "" "InvalidArgument"

log ""
log "########################"
log "# 19. Valid structure but invalid destination should fail"
log "########################"

require_tf "s3api put-bucket-notification-configuration (invalid destination)" TF_S3_BUCKET_PERMISSIONS && validate_expected_error_match "s3api put-bucket-notification-configuration (invalid destination)" "aws s3api put-bucket-notification-configuration --bucket $S3_TEST_BUCKET --notification-configuration file://s3_bucket_notification_valid.json" "" "InvalidArgument"

log ""
log "########################"
log "# 20. Should fail and give Invalid ARN, testing endpoint resolution"
log "########################"

validate_expected_error_match "stepfunctions start-sync-execution (should fail with InvalidArn)" "aws stepfunctions start-sync-execution --state-machine-arn Foo" "" "InvalidArn"

log ""
log "########################"
log "# 21. Validate values are rewritten should pass"
log "########################"

validate_rewrite_smart "cloudformation describe-stack-events" "aws cloudformation describe-stack-events --stack-name Combine-${SHARD}" ""
validate_rewrite_smart "cloudformation describe-stacks" "aws cloudformation describe-stacks --stack-name Combine-${SHARD}" ""
validate_rewrite_smart "cloudformation describe-type (IAM::Role)" "aws cloudformation describe-type --type-name AWS::IAM::Role --type RESOURCE" ""
validate_rewrite_smart "cloudformation describe-type (EC2::Instance)" "aws cloudformation describe-type --type-name AWS::EC2::Instance --type RESOURCE" ""
validate_rewrite_smart "cloudformation list-exports" "aws cloudformation list-exports" ""

log ""
log "########################"
log "# 22. Validate values are rewritten should pass"
log "########################"

validate_rewrite_smart "configservice describe-compliance-by-resource" "aws configservice describe-compliance-by-resource --resource-type AWS::ACM::Certificate --resource-id arn:aws-iso:acm:us-iso-east-1:663117128738:certificate/0f696b33-57e2-43d5-b3c6-323e77229cbd" ""
validate_rewrite_smart "configservice describe-configuration-recorders" "aws configservice describe-configuration-recorders" ""

log ""
log "########################"
log "# 23. CloudTrail rewrite and error validation"
log "########################"


CLI_TRAIL_NAME="CombineTest${RUN_SUFFIX}"
require_tf "cloudtrail create-trail" TF_S3_BUCKET_CLOUDTRAIL TF_CLOUDWATCH_LOG_GROUP_ARN TF_IAM_ROLE_ARN TF_KMS_KEY_ARN && validate_rewrite_smart "cloudtrail create-trail" "aws cloudtrail create-trail --name $CLI_TRAIL_NAME --s3-bucket-name $TF_S3_BUCKET_CLOUDTRAIL --s3-key-prefix EndpointsTest --no-is-multi-region-trail --no-include-global-service-events --cloud-watch-logs-log-group-arn '${TF_CLOUDWATCH_LOG_GROUP_ARN}:*' --cloud-watch-logs-role-arn $TF_IAM_ROLE_ARN --kms-key-id $TF_KMS_KEY_ARN" "" ".TrailARN" "TRAIL_ARN"
validate_rewrite_smart "cloudtrail list-trails" "aws cloudtrail list-trails" ""
validate_rewrite_smart "cloudtrail describe-trails" "aws cloudtrail describe-trails --trail-name-list \$TRAIL_ARN" ""
validate_rewrite_smart "cloudtrail get-trail" "aws cloudtrail get-trail --name \$TRAIL_ARN" ""
validate_success "cloudtrail get-trail-status" "aws cloudtrail get-trail-status --name \$TRAIL_ARN"

validate_rewrite_smart "cloudtrail put-event-selectors (valid)" "aws cloudtrail put-event-selectors --trail-name $CLI_TRAIL_NAME --event-selectors file://cloudtrail_event_selector_valid.json" ""
validate_rewrite_smart "cloudtrail get-event-selectors" "aws cloudtrail get-event-selectors --trail-name $CLI_TRAIL_NAME" ""

validate_expected_error_match "cloudtrail put-event-selectors (invalid S3 ARN)" "aws cloudtrail put-event-selectors --trail-name $CLI_TRAIL_NAME --event-selectors file://cloudtrail_event_selector_invalid_s3.json" "Unexpected Value for ARN"
validate_expected_error_match "cloudtrail put-event-selectors (invalid Lambda ARN format)" "aws cloudtrail put-event-selectors --trail-name $CLI_TRAIL_NAME --event-selectors file://cloudtrail_event_selector_invalid_lambda.json" "Unexpected Value for ARN"

record_cmd "aws cloudtrail delete-trail --name \$TRAIL_ARN"
aws cloudtrail delete-trail --name "${TRAIL_ARN:-}" >/dev/null 2>&1 && log "🧼 Deleted trail ${TRAIL_ARN:-}"
unset TRAIL_ARN

log ""
log "########################"
log "# 24. Validate values are rewritten in response (DynamoDB)"
log "########################"


require_tf "dynamodb describe-table" TF_DYNAMODB_TABLE_NAME && validate_rewrite_smart "dynamodb describe-table" "aws dynamodb describe-table --table-name \$TF_DYNAMODB_TABLE_NAME" ""
require_tf "dynamodb create-backup" TF_DYNAMODB_TABLE_NAME && validate_rewrite_smart "dynamodb create-backup" "aws dynamodb create-backup --table-name \$TF_DYNAMODB_TABLE_NAME --backup-name Test1" "" ".BackupDetails.BackupArn" "DDB_BACKUP_ARN"
require_tf "dynamodb describe-backup" TF_DYNAMODB_TABLE_NAME && validate_rewrite_smart "dynamodb describe-backup" "aws dynamodb describe-backup --backup-arn \$DDB_BACKUP_ARN" ""
require_tf "dynamodb list-backups" TF_DYNAMODB_TABLE_NAME && validate_rewrite_smart "dynamodb list-backups" "aws dynamodb list-backups --table-name \$TF_DYNAMODB_TABLE_NAME" ""
require_tf "dynamodb delete-backup" TF_DYNAMODB_TABLE_NAME && validate_rewrite_smart "dynamodb delete-backup" "aws dynamodb delete-backup --backup-arn \$DDB_BACKUP_ARN" ""
require_tf "dynamodbstreams list-streams" TF_DYNAMODB_TABLE_NAME && validate_rewrite_smart "dynamodbstreams list-streams" "aws dynamodbstreams list-streams --table-name \$TF_DYNAMODB_TABLE_NAME --region us-iso-east-1" "" ".Streams[0].StreamArn" "STREAM_ARN"
require_tf "dynamodbstreams describe-stream" TF_DYNAMODB_TABLE_NAME && validate_rewrite_smart "dynamodbstreams describe-stream" "aws dynamodbstreams describe-stream --stream-arn \$STREAM_ARN --region us-iso-east-1" "" ".StreamDescription.Shards[0].ShardId" "SHARD_ID"
require_tf "dynamodbstreams get-shard-iterator" TF_DYNAMODB_TABLE_NAME && validate_rewrite_smart "dynamodbstreams get-shard-iterator" "aws dynamodbstreams get-shard-iterator --stream-arn \$STREAM_ARN --shard-id \$SHARD_ID --shard-iterator-type LATEST --region us-iso-east-1" "" ".ShardIterator" "SHARD_ITERATOR_ID"
require_tf "dynamodbstreams get-records" TF_DYNAMODB_TABLE_NAME && validate_rewrite_smart "dynamodbstreams get-records" "aws dynamodbstreams get-records --shard-iterator \$SHARD_ITERATOR_ID --region us-iso-east-1" "" ".NextShardIterator" "NEXT_SHARD_ITERATOR_ID"
require_tf "dynamodbstreams get-records (next iterator)" TF_DYNAMODB_TABLE_NAME && validate_rewrite_smart "dynamodbstreams get-records (next iterator)" "aws dynamodbstreams get-records --shard-iterator \$NEXT_SHARD_ITERATOR_ID --region us-iso-east-1" ""

log ""
log "########################"
log "# 25. ECR – Validate values are rewritten in response"
log "########################"

validate_rewrite_smart "ecr describe-repositories" "aws ecr describe-repositories" ""

validate_rewrite_smart "ecr put-registry-policy" "aws ecr put-registry-policy --policy-text '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws-iso:iam::663117128738:root\"},\"Action\":[\"ecr:CreateRepository\"],\"Resource\": [\"arn:aws-iso:ecr:us-iso-east-1:663117128738:repository/*\"]}]}'" ""
validate_rewrite_smart "ecr get-registry-policy" "aws ecr get-registry-policy" ""
validate_rewrite_smart "ecr delete-registry-policy" "aws ecr delete-registry-policy" ""

validate_rewrite_smart "ecr create-repository" "aws ecr create-repository --repository-name combine/endpoints-test" ""
validate_rewrite_smart "ecr set-repository-policy" "aws ecr set-repository-policy --repository-name combine/endpoints-test --policy-text '{\"Version\": \"2012-10-17\",\"Statement\": [{\"Sid\": \"AllowCrossAccountPush\",\"Effect\": \"Allow\",\"Principal\": {\"AWS\": \"arn:aws-iso:iam::663117128738:root\"},\"Action\": [\"ecr:BatchCheckLayerAvailability\",\"ecr:CompleteLayerUpload\",\"ecr:InitiateLayerUpload\",\"ecr:PutImage\",\"ecr:UploadLayerPart\"]}]}'" ""
validate_rewrite_smart "ecr delete-repository" "aws ecr delete-repository --repository-name combine/endpoints-test" ""

log ""
log "########################"
log "# 26. EC2 – Should fail with credential validation error"
log "########################"

require_isob "ec2 describe-instances (auth failure)" && validate_expected_error_match "ec2 describe-instances (auth failure)" "aws ec2 describe-instances --region us-isob-east-1 --endpoint-url https://ec2.us-iso-east-1.c2s.ic.gov" "AWS was not able to validate the provided access credentials"

log ""
log "########################"
log "# 27. FIPS endpoint tests"
log "########################"

validate_expected_error_match "ec2 describe-regions (fips unsupported)" "aws ec2 describe-regions --endpoint-url https://ec2-fips.us-iso-east-1.c2s.ic.gov" "EmulationError"
validate_rewrite_smart "kms list-keys (fips)" "aws kms list-keys --endpoint-url https://kms-fips.us-iso-east-1.c2s.ic.gov" ""

log ""
log "########################"
log "# 28. Dualstack endpoint tests"
log "########################"

validate_expected_error_match "s3api list-buckets (dualstack unsupported)" "aws s3api list-buckets --endpoint-url https://s3.dualstack.us-iso-east-1.c2s.ic.gov" "EmulationError"

log ""
log "########################"
log "# 29. Glacier – validate values are rewritten in response"
log "########################"

validate_rewrite_smart "glacier list-vaults" "aws glacier list-vaults --account-id 663117128738" ""
require_tf "glacier describe-vault" TF_GLACIER_VAULT_NAME && validate_rewrite_smart "glacier describe-vault" "aws glacier describe-vault --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME" ""
require_tf "glacier set-vault-notifications" TF_GLACIER_VAULT_NAME TF_SNS_TOPIC_2_ARN && validate_success "glacier set-vault-notifications" "aws glacier set-vault-notifications --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME --vault-notification-config SNSTopic=$TF_SNS_TOPIC_2_ARN,Events=ArchiveRetrievalCompleted,InventoryRetrievalCompleted"
require_tf "glacier get-vault-notifications" TF_GLACIER_VAULT_NAME && validate_rewrite_smart "glacier get-vault-notifications" "aws glacier get-vault-notifications --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME" ""
require_tf "glacier delete-vault-notifications" TF_GLACIER_VAULT_NAME && validate_success "glacier delete-vault-notifications" "aws glacier delete-vault-notifications --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME"
require_tf "glacier set-vault-access-policy" TF_GLACIER_VAULT_NAME && validate_success "glacier set-vault-access-policy" "aws glacier set-vault-access-policy --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME --policy '{\"Policy\":\"{\\\"Version\\\": \\\"2012-10-17\\\",\\\"Statement\\\": [{\\\"Sid\\\": \\\"CombineTest\\\",\\\"Effect\\\": \\\"Allow\\\",\\\"Principal\\\": {\\\"AWS\\\": \\\"arn:aws-iso:iam::663117128738:root\\\"},\\\"Action\\\": \\\"glacier:*\\\",\\\"Resource\\\": \\\"arn:aws-iso:glacier:us-iso-east-1:663117128738:vaults/$TF_GLACIER_VAULT_NAME\\\"}]}\"}'"
require_tf "glacier get-vault-access-policy" TF_GLACIER_VAULT_NAME && validate_rewrite_smart "glacier get-vault-access-policy" "aws glacier get-vault-access-policy --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME" ""
require_tf "glacier delete-vault-access-policy" TF_GLACIER_VAULT_NAME && validate_success "glacier delete-vault-access-policy" "aws glacier delete-vault-access-policy --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME"
require_tf "glacier initiate-vault-lock" TF_GLACIER_VAULT_NAME && validate_success "glacier initiate-vault-lock" "aws glacier initiate-vault-lock --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME --policy '{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Sid\\\":\\\"CombineTest\\\",\\\"Principal\\\":\\\"*\\\",\\\"Effect\\\":\\\"Deny\\\",\\\"Action\\\":\\\"glacier:DeleteArchive\\\",\\\"Resource\\\":[\\\"arn:aws-iso:glacier:us-iso-east-1:663117128738:vaults/$TF_GLACIER_VAULT_NAME\\\"],\\\"Condition\\\":{\\\"NumericLessThan\\\":{\\\"glacier:ArchiveAgeInDays\\\":\\\"7\\\"}}}]}\"}'"
require_tf "glacier get-vault-lock" TF_GLACIER_VAULT_NAME && validate_success "glacier get-vault-lock" "aws glacier get-vault-lock --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME"
require_tf "glacier abort-vault-lock" TF_GLACIER_VAULT_NAME && validate_success "glacier abort-vault-lock" "aws glacier abort-vault-lock --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME"

log ""
log "########################"
log "# 30. Step Functions – validate values are rewritten in response"
log "########################"

validate_rewrite_smart "stepfunctions create-activity" "aws stepfunctions create-activity --name Foo" ""
validate_rewrite_smart "stepfunctions list-activities (first pass)" "aws stepfunctions list-activities" ""
validate_rewrite_smart "stepfunctions describe-activity" "aws stepfunctions describe-activity --activity-arn arn:aws-iso:states:us-iso-east-1:663117128738:activity:Foo" ""
validate_success "stepfunctions delete-activity" "aws stepfunctions delete-activity --activity-arn arn:aws-iso:states:us-iso-east-1:663117128738:activity:Foo"
validate_success "stepfunctions list-activities (after delete)" "aws stepfunctions list-activities"

log ""
log "########################"
log "# 31. SSM – Should pass wont return rewritten values"
log "########################"

require_tf "ssm put-parameter (SecureString)" TF_KMS_KEY_ARN && validate_success "ssm put-parameter (SecureString)" "aws ssm put-parameter --name Test2${RUN_SUFFIX} --value Test --type SecureString --key-id $TF_KMS_KEY_ARN"
require_tf "ssm delete-parameter" TF_KMS_KEY_ARN && validate_success "ssm delete-parameter" "aws ssm delete-parameter --name Test2${RUN_SUFFIX}" ""

log ""
log "########################"
log "# 32. Glacier – Will fail (however we need to verify the endpoint logs through cloudwatch and I have no idea how to autoamte this currently, so commenting here.)"
log "########################"

require_tf "glacier initiate-job (should fail)" TF_GLACIER_VAULT_NAME && validate_expected_error_match "glacier initiate-job (should fail)" "aws glacier initiate-job --account-id 663117128738 --vault-name $TF_GLACIER_VAULT_NAME --job-parameters file://glacier_job.json" "ResourceNotFoundException"

log ""
log "########################"
log "# 33. ELBv2 Should fail, not implemented"
log "########################"

validate_expected_error_match "elbv2 create-load-balancer (not implemented)" "aws elbv2 create-load-balancer --name Foo --type network --subnet-mappings SubnetId=foo SubnetId=bar SubnetId=baz,PrivateIPv4Address=10.0.0.2" "Combine rejected this AWS API request because it is not implemented"
validate_expected_error_match "elbv2 set-subnets (not implemented)" "aws elbv2 set-subnets --load-balancer-arn Foo --subnet-mappings SubnetId=foo SubnetId=bar SubnetId=baz,PrivateIPv4Address=10.0.0.2" "Combine rejected this AWS API request because it is not implemented"
validate_expected_error_match "elbv2 create-load-balancer (security groups not implemented)" "aws elbv2 create-load-balancer --name Foo --type network --security-groups foo" "Combine rejected this AWS API request because it is not implemented"
validate_expected_error_match "elbv2 set-security-groups (not implemented)" "aws elbv2 set-security-groups --load-balancer-arn foo --security-groups foo" "Combine rejected this AWS API request because it is not implemented"

log ""
log "########################"
log "# 34. S3 presigned URL – MD5 checksum should match"
log "########################"

validate_s3 "s3 presign checksum test (smallfile.txt)" "smallfile.txt" "foo/smallfile.txt" "presign"

log ""
log "########################"
log "# 35. S3 presign text content validation"
log "########################"

validate_s3 "s3 presign upload + wget (text validation)" "test_cli_presign_upload.txt" "foo/bar++/baz//boz//bix//test.txt" "presign"
validate_success "cat presigned file content" "cat test_cli_presign_upload.txt_back" "How is your monkey's uncle?" ##this fails because validate_s3 deletes the back file before this check can run

log ""
log "########################"
log "# 36. S3 presign download - checksum match"
log "########################"

validate_s3 "s3 presign file.txt (checksum)" "file.txt" "foo/file.txt" "checksum"

log ""
log "########################"
log "# 37. S3 Location Constraint & Tagging Tests"
log "########################"

validate_success "s3api create-bucket" "aws s3api create-bucket --bucket combine-cli-lc${RUN_SUFFIX,,} --create-bucket-configuration LocationConstraint=\"us-iso-east-1\""
validate_rewrite_smart "s3api get-bucket-location" "aws s3api get-bucket-location --bucket combine-cli-lc${RUN_SUFFIX,,}" ""
validate_success "s3api put-bucket-tagging" "aws s3api put-bucket-tagging --bucket combine-cli-lc${RUN_SUFFIX,,} --tagging \"TagSet=[{Key=foo,Value=bar}]\""
validate_success "s3api get-bucket-tagging" "aws s3api get-bucket-tagging --bucket combine-cli-lc${RUN_SUFFIX,,}"
validate_success "s3api delete-bucket" "aws s3api delete-bucket --bucket combine-cli-lc${RUN_SUFFIX,,}"
validate_success "s3api create-bucket (us-iso-west-1)" "aws s3api create-bucket --bucket combine-cli-lc-usiw1${RUN_SUFFIX,,} --create-bucket-configuration LocationConstraint=us-iso-west-1"
validate_rewrite_smart "s3api get-bucket-location (us-iso-west-1)" "aws s3api get-bucket-location --bucket combine-cli-lc-usiw1${RUN_SUFFIX,,}" ""
validate_success "s3api delete-bucket (us-iso-west-1)" "aws s3api delete-bucket --bucket combine-cli-lc-usiw1${RUN_SUFFIX,,}"

log ""
log "########################"
log "# 38. SQS Attribute Validation Tests"
log "########################"

validate_rewrite_smart "sqs create-queue (TestRedrive)" "aws sqs create-queue --queue-name TestRedrive" ""
validate_rewrite_smart "sqs create-queue (Test w/ attributes)" "aws sqs create-queue --queue-name Test --attributes file://test_queue.json" ""
validate_success "sqs delete-queue (Test)" "aws sqs delete-queue --queue-url https://sqs.us-iso-east-1.c2s.ic.gov/663117128738/Test"
validate_rewrite_smart "sqs create-queue (Test2)" "aws sqs create-queue --queue-name Test2" ""
validate_success "sqs set-queue-attributes (Test2)" "aws sqs set-queue-attributes --attributes file://test_queue.json --queue-url https://sqs.us-iso-east-1.c2s.ic.gov/663117128738/Test2"
validate_rewrite_smart "sqs get-queue-attributes (Test2)" "aws sqs get-queue-attributes --attribute-names All --queue-url https://sqs.us-iso-east-1.c2s.ic.gov/663117128738/Test2" ""

log ""
log "########################"
log "# 38b. SQS Redrive Policy Failure and Cleanup"
log "########################"

validate_expected_error_match "sqs set-queue-attributes (nonexistent queues)" "aws sqs set-queue-attributes --queue-url \"https://sqs.us-iso-east-1.c2s.ic.gov/663117128738/bti360-horizon-sequoia-highlight-uploads-dlq\" --attributes '{\"RedriveAllowPolicy\":\"{\\\"redrivePermission\\\": \\\"byQueue\\\", \\\"sourceQueueArns\\\": [\\\"arn:aws-iso:sqs:us-iso-east-1:663117128738:nonexistent\\\",\\\"arn:aws-iso:sqs:us-iso-east-1:663117128738:also-nonexistent\\\",\\\"arn:aws-iso:sqs:us-iso-east-1:663117128738:lastly-nonexistent\\\"]}\"}'" "AWS.SimpleQueueService.NonExistentQueue"

validate_success "sqs delete-queue (Test2 cleanup)" "aws sqs delete-queue --queue-url https://sqs.us-iso-east-1.c2s.ic.gov/663117128738/Test2"

log ""
log "########################"
log "# 39. SQS ISO-B Queue Creation & Cleanup"
log "########################"

require_isob "sqs create-queue (ISO-B)" && validate_rewrite_smart "sqs create-queue (ISO-B)" "aws sqs create-queue --queue-name TestB --attributes file://test_queue_isob.json --region us-isob-east-1 --endpoint-url https://sqs.us-isob-east-1.sc2s.sgov.gov"
require_isob "sqs delete-queue (ISO-B)" && validate_success "sqs delete-queue (ISO-B)" "aws sqs delete-queue --queue-url https://sqs.us-isob-east-1.sc2s.sgov.gov/663117128738/TestB --region us-isob-east-1 --endpoint-url https://sqs.us-isob-east-1.sc2s.sgov.gov"

log ""
log "########################"
log "# 40. S3 Bucket Policy Rewrite Validation"
log "########################"

require_tf "s3api put-bucket-policy" TF_S3_BUCKET_PERMISSIONS && validate_success "s3api put-bucket-policy" "aws s3api put-bucket-policy --bucket $S3_TEST_BUCKET --policy '{ \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"AWS\": \"arn:aws-iso:iam::770363063475:root\" }, \"Action\": [ \"s3:*\" ], \"Resource\": [ \"arn:aws-iso:s3:::$S3_TEST_BUCKET\", \"arn:aws-iso:s3:::$S3_TEST_BUCKET/*\" ] } ] }'"
require_tf "s3api get-bucket-policy" TF_S3_BUCKET_PERMISSIONS && validate_rewrite_smart "s3api get-bucket-policy" "aws s3api get-bucket-policy --bucket $S3_TEST_BUCKET"
require_tf "s3api delete-bucket-policy" TF_S3_BUCKET_PERMISSIONS && validate_success "s3api delete-bucket-policy" "aws s3api delete-bucket-policy --bucket $S3_TEST_BUCKET"

log ""
log "########################"
log "# 41. EC2 describe-availability-zones"
log "########################"

validate_rewrite_smart "ec2 describe-availability-zones (filters by region and zone-id)" "aws ec2 describe-availability-zones --filters Name=region-name,Values=us-iso-east-1 Name=zone-id,Values=usie1-az1,usie1-az2"
validate_rewrite_smart "ec2 describe-availability-zones (zone-ids usie)" "aws ec2 describe-availability-zones --zone-ids usie1-az1 usie1-az2"
require_isob "ec2 describe-availability-zones (zone-ids usibe)" && validate_rewrite_smart "ec2 describe-availability-zones (zone-ids usibe)" "aws ec2 describe-availability-zones --zone-ids usibe1-az1 usibe1-az2 --region us-isob-east-1"
validate_rewrite_smart "ec2 describe-availability-zones (zone-names us-iso)" "aws ec2 describe-availability-zones --zone-names us-iso-east-1a us-iso-east-1b"
require_isob "ec2 describe-availability-zones (zone-names us-isob)" && validate_rewrite_smart "ec2 describe-availability-zones (zone-names us-isob)" "aws ec2 describe-availability-zones --zone-names us-isob-east-1a us-isob-east-1b --region us-isob-east-1"
validate_rewrite_smart "ec2 describe-availability-zones (filter by single zone-id usie)" "aws ec2 describe-availability-zones --filters Name=zone-id,Values=usie1-az1"
require_isob "ec2 describe-availability-zones (filter by single zone-id usibe)" && validate_rewrite_smart "ec2 describe-availability-zones (filter by single zone-id usibe)" "aws ec2 describe-availability-zones --filters Name=zone-id,Values=usibe1-az1 --region us-isob-east-1"
validate_rewrite_smart "ec2 describe-availability-zones (filter by zone-name us-iso)" "aws ec2 describe-availability-zones --filters Name=zone-name,Values=us-iso-east-1a"
require_isob "ec2 describe-availability-zones (filter by zone-name us-isob)" && validate_rewrite_smart "ec2 describe-availability-zones (filter by zone-name us-isob)" "aws ec2 describe-availability-zones --filters Name=zone-name,Values=us-isob-east-1a --region us-isob-east-1"

log ""
log "########################"
log "# 42. EC2 filtering and response validation"
log "########################"

validate_rewrite_smart "ec2 describe-subnets (filter: AZ, VPC, owner-id)" "aws ec2 describe-subnets --filters \"Name=owner-id,Values=663117128738\" \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\" \"Name=vpc-id,Values=\$VPC_ID\""
validate_rewrite_smart "ec2 describe-instances (filter: AZ, VPC, owner-id)" "aws ec2 describe-instances --filters \"Name=owner-id,Values=663117128738\" \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\" \"Name=vpc-id,Values=\$VPC_ID\""
validate_rewrite_smart "ec2 describe-instance-status (filter: AZ)" "aws ec2 describe-instance-status --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-volumes (filter: AZ)" "aws ec2 describe-volumes --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-volume-status (filter: AZ)" "aws ec2 describe-volume-status --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_success "ec2 describe-reserved-instances (filter: AZ)" "aws ec2 describe-reserved-instances --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-reserved-instances-offerings (filter: AZ, max-items)" "aws ec2 describe-reserved-instances-offerings --max-items 10 --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-network-interfaces (filter: AZ)" "aws ec2 describe-network-interfaces --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_success "ec2 describe-capacity-reservations (filter: AZ)" "aws ec2 describe-capacity-reservations --filter \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-availability-zones (region us-iso)" "aws ec2 describe-availability-zones --filters Name=region-name,Values=us-iso-east-1"
require_isob "ec2 describe-availability-zones (region us-isob)" && validate_rewrite_smart "ec2 describe-availability-zones (region us-isob)" "aws ec2 describe-availability-zones --filters Name=region-name,Values=us-isob-east-1 --region us-isob-east-1"

log ""
log "########################"
log "# 43. VPC endpoint service name rewriting"
log "########################"

validate_rewrite_smart "ec2 describe-vpc-endpoint-services (iso)" "aws ec2 describe-vpc-endpoint-services --service-names gov.ic.c2s.us-iso-east-1.elasticfilesystem"
require_isob "ec2 describe-vpc-endpoint-services (isob)" && validate_rewrite_smart "ec2 describe-vpc-endpoint-services (isob)" "aws ec2 describe-vpc-endpoint-services --service-names gov.sgov.sc2s.us-isob-east-1.elasticfilesystem --region us-isob-east-1"

log ""
log "########################"
log "# 44. Will pass, validate S3 service name"
log "########################"

validate_rewrite_smart "ec2 vpc-endpoint-services (iso)" "aws ec2 describe-vpc-endpoint-services --service-names com.amazonaws.us-iso-east-1.s3" ""
require_isob "ec2 vpc-endpoint-services (isob)" && validate_rewrite_smart "ec2 vpc-endpoint-services (isob)" "aws ec2 describe-vpc-endpoint-services --service-names com.amazonaws.us-isob-east-1.s3 --region us-isob-east-1" ""

log ""
log "########################"
log "# 45. EC2 create/delete subnet and volume"
log "########################"

validate_rewrite_smart "ec2 create-subnet (AZ name)" "aws ec2 create-subnet --vpc-id \$VPC_ID --cidr-block 10.0.80.0/24 --availability-zone us-iso-east-1d" "" ".Subnet.SubnetId" "SUBNET_ID_1"
validate_success "ec2 delete-subnet" "aws ec2 delete-subnet --subnet-id \$SUBNET_ID_1"
validate_rewrite_smart "ec2 create-subnet (AZ ID)" "aws ec2 create-subnet --vpc-id \$VPC_ID --cidr-block 10.0.80.0/24 --availability-zone-id usie1-az1" "" ".Subnet.SubnetId" "SUBNET_ID_2"
validate_success "ec2 delete-subnet" "aws ec2 delete-subnet --subnet-id \$SUBNET_ID_2"
validate_rewrite_smart "ec2 create-volume" "aws ec2 create-volume --availability-zone us-iso-east-1d --size 8" "" ".VolumeId" "VOLUME_ID"
validate_success "ec2 delete-volume" "aws ec2 delete-volume --volume-id \$VOLUME_ID"

log ""
log "########################"
log "# 46. Elasticache instance type test, first pass no results, second pass results"
log "########################"

validate_success "cache.m6g.large (should return empty array)"  "aws elasticache describe-reserved-cache-nodes-offerings --cache-node-type cache.m6g.large"
validate_success "cache.m5.large (should return data)" "aws elasticache describe-reserved-cache-nodes-offerings --cache-node-type cache.m5.large" "__nonempty__"

log ""
log "########################"
log "# 47. Elasticache encryption violation (actually Combine rejection)"
log "########################"

validate_expected_error_match "elasticache create-cache-cluster with encryption" "aws elasticache create-cache-cluster --cache-cluster-id foo --engine redis --cache-node-type cache.m5.large --num-cache-nodes 1 --transit-encryption-enabled --region us-iso-east-1" "Combine rejected this AWS API"
validate_expected_error_match "elasticache create-replication-group with encryption" "aws elasticache create-replication-group --replication-group-id foo --replication-group-description foo --engine redis --cache-node-type cache.m5.large --transit-encryption-enabled --region us-iso-east-1" "Combine rejected this AWS API"
validate_expected_error_match "elasticache modify-replication-group with encryption" "aws elasticache modify-replication-group --replication-group-id foo --transit-encryption-enabled --region us-iso-east-1" "Combine rejected this AWS API"

log ""
log "########################"
log "# 48. OpenSearch and ES domain creation should fail (EBS storage must be selected)"
log "########################"

validate_expected_error_match "opensearch create-domain (OpenSearch_2.17)" "aws opensearch create-domain --domain-name foo --engine-version OpenSearch_2.17" "EBS storage must be selected"
validate_expected_error_match "opensearch create-domain (Elasticsearch_7.10)" "aws opensearch create-domain --domain-name foo --engine-version Elasticsearch_7.10" "EBS storage must be selected"
validate_expected_error_match "es create-elasticsearch-domain (OpenSearch_2.17)" "aws es create-elasticsearch-domain --domain-name foo --elasticsearch-version OpenSearch_2.17" "EBS storage must be selected"
validate_expected_error_match "es create-elasticsearch-domain (7.10)" "aws es create-elasticsearch-domain --domain-name foo --elasticsearch-version 7.10" "EBS storage must be selected"

log ""
log "########################"
log "# 49. OpenSearch and ES version tests – should fail with 'Unsupported Elasticsearch Version'"
log "########################"

validate_expected_error_match "opensearch create-domain (OpenSearch_2.10)" "aws opensearch create-domain --domain-name foo --engine-version OpenSearch_2.10" "Unsupported Elasticsearch Version"
validate_expected_error_match "opensearch upgrade-domain (OpenSearch_2.10)" "aws opensearch upgrade-domain --domain-name foo --target-version OpenSearch_2.10" "Unsupported Elasticsearch Version"
validate_expected_error_match "es create-elasticsearch-domain (OpenSearch_2.10)" "aws es create-elasticsearch-domain --domain-name foo --elasticsearch-version OpenSearch_2.10" "Unsupported Elasticsearch Version"
validate_expected_error_match "es upgrade-elasticsearch-domain (OpenSearch_2.10)" "aws es upgrade-elasticsearch-domain --domain-name foo --target-version OpenSearch_2.10" "Unsupported Elasticsearch Version"
validate_expected_error_match "opensearch create-domain (Elasticsearch_7.3)" "aws opensearch create-domain --domain-name foo --engine-version Elasticsearch_7.3" "Unsupported Elasticsearch Version"
validate_expected_error_match "opensearch upgrade-domain (Elasticsearch_7.3)" "aws opensearch upgrade-domain --domain-name foo --target-version Elasticsearch_7.3" "Unsupported Elasticsearch Version"
validate_expected_error_match "es create-elasticsearch-domain (Elasticsearch_7.3)" "aws es create-elasticsearch-domain --domain-name foo --elasticsearch-version Elasticsearch_7.3" "Unsupported Elasticsearch Version"
validate_expected_error_match "es upgrade-elasticsearch-domain (Elasticsearch_7.3)" "aws es upgrade-elasticsearch-domain --domain-name foo --target-version Elasticsearch_7.3" "Unsupported Elasticsearch Version"

log ""
log "########################"
log "# 50. OpenSearch and ES version listings – should pass"
log "# Note: These currently only validate successful response. Consider checking version list in future."
log "########################"

validate_success "opensearch get-compatible-versions" "aws opensearch get-compatible-versions"
validate_success "opensearch list-versions" "aws opensearch list-versions"
validate_success "es get-compatible-elasticsearch-versions" "aws es get-compatible-elasticsearch-versions"
validate_success "es list-elasticsearch-versions" "aws es list-elasticsearch-versions"

log ""
log "########################"
log "# 51. Kinesis Stream (Terraform-managed)"
log "########################"

require_tf "kinesis list-streams (Terraform stream)" TF_KINESIS_STREAM_NAME && validate_rewrite_smart "kinesis list-streams (Terraform stream)" "aws kinesis list-streams" "" ".StreamSummaries[] | select(.StreamName==\"$TF_KINESIS_STREAM_NAME\") | .StreamARN" "TF_KINESIS_ARN"
require_tf "kinesis describe-stream" TF_KINESIS_STREAM_NAME && validate_rewrite_smart "kinesis describe-stream" "aws kinesis describe-stream --stream-arn \$TF_KINESIS_ARN" "" ".StreamDescription.StreamStatus"
require_tf "kinesis decrease-stream-retention" TF_KINESIS_STREAM_NAME && validate_success "kinesis decrease-stream-retention" "aws kinesis decrease-stream-retention-period --stream-arn \$TF_KINESIS_ARN --retention-period-hours 24"

log ""
log "########################"
log "# 52. SWF Domain Tagging & Rewriting"
log "########################"

# Attempt to register domain, ignore if already exists
record_cmd "aws swf register-domain --name CombineTest --workflow-execution-retention-period-in-days 1"
if aws swf register-domain --name CombineTest --workflow-execution-retention-period-in-days 1 2>&1 | grep -q "DomainAlreadyExistsFault"; then
  log "ℹ️  Domain CombineTest already exists. Attempting undeprecate."
  validate_success "swf undeprecate-domain" "aws swf undeprecate-domain --name CombineTest"
else
  log "✅ Domain CombineTest registered."
fi

validate_rewrite_smart "swf describe-domain" "aws swf describe-domain --name CombineTest"
validate_success "swf list-tags (should be empty initially)" "aws swf list-tags-for-resource --resource-arn arn:aws-iso:swf:us-iso-east-1:663117128738:/domain/CombineTest"
validate_success "swf tag-resource" "aws swf tag-resource --resource-arn arn:aws-iso:swf:us-iso-east-1:663117128738:/domain/CombineTest --tags key=Test,value=Test"
validate_success "swf list-tags (should contain tag)" "aws swf list-tags-for-resource --resource-arn arn:aws-iso:swf:us-iso-east-1:663117128738:/domain/CombineTest" "Test"
validate_success "swf untag-resource" "aws swf untag-resource --resource-arn arn:aws-iso:swf:us-iso-east-1:663117128738:/domain/CombineTest --tag-keys Test"
validate_success "swf list-tags (should now be empty again)" "aws swf list-tags-for-resource --resource-arn arn:aws-iso:swf:us-iso-east-1:663117128738:/domain/CombineTest"
validate_success "swf deprecate-domain" "aws swf deprecate-domain --name CombineTest"

log ""
log "########################"
log "# 53. RDS Cluster + Instance End-to-End"
log "########################"


require_long "create-db-instance 2" && require_tf "create-db-instance 2" TF_RDS_SUBNET_GROUP_NAME && validate_rewrite_smart "create-db-instance 2" "aws rds create-db-instance --master-username combineadmin --master-user-password Combine1275317 --db-subnet-group-name \$TF_RDS_SUBNET_GROUP_NAME --db-instance-identifier CombineEndpointTestInstance2 --db-instance-class db.t3.micro --allocated-storage 8 --engine mysql --availability-zone us-iso-east-1a"
require_long "create-db-cluster 2" && require_tf "create-db-cluster 2" TF_RDS_SUBNET_GROUP_NAME && validate_rewrite_smart "create-db-cluster 2" "aws rds create-db-cluster --master-username combineadmin --master-user-password Combine1275317 --db-cluster-identifier CombineEndpointTestCluster2 --db-subnet-group-name \$TF_RDS_SUBNET_GROUP_NAME --engine aurora-postgresql --availability-zones us-iso-east-1a us-iso-east-1b us-iso-east-1c"
validate_rewrite_smart "describe-db-instances" "aws rds describe-db-instances"
validate_rewrite_smart "describe-db-clusters" "aws rds describe-db-clusters"
validate_rewrite_smart "describe-db-subnet-groups" "aws rds describe-db-subnet-groups"
require_long "delete-db-instance 2" && require_tf "delete-db-instance 2" TF_RDS_SUBNET_GROUP_NAME && validate_rewrite_smart "delete-db-instance 2" "aws rds delete-db-instance --skip-final-snapshot --db-instance-identifier CombineEndpointTestInstance2"
require_long "delete-db-cluster 2" && require_tf "delete-db-cluster 2" TF_RDS_SUBNET_GROUP_NAME && validate_rewrite_smart "delete-db-cluster 2" "aws rds delete-db-cluster --skip-final-snapshot --db-cluster-identifier CombineEndpointTestCluster2"
if [[ "$LONG_TESTS" == "true" && -n "$TF_RDS_SUBNET_GROUP_NAME" ]]; then
  wait_rds_deleted instance CombineEndpointTestInstance2
  wait_rds_deleted cluster CombineEndpointTestCluster2
fi

log ""
log "########################"
log "# 54. RDS instance type will fail due to instance type"
log "########################"

require_tf "unsupported RDS instance type" TF_RDS_SUBNET_GROUP_NAME && validate_expected_error_match "unsupported RDS instance type" "aws rds create-db-instance --master-username combineadmin --master-user-password Combine1275317 --db-subnet-group-name \$TF_RDS_SUBNET_GROUP_NAME --db-instance-identifier CombineEndpointTestInstanceInvalid --db-instance-class \$UNSUPPORTED_INSTANCE_TYPE --allocated-storage 8 --engine mysql --availability-zone us-iso-east-1a" "Invalid DB Instance class"
require_long "create-db-instance supported type" && require_tf "create-db-instance supported type" TF_RDS_SUBNET_GROUP_NAME && validate_rewrite_smart "create-db-instance supported type" "aws rds create-db-instance --master-username combineadmin --master-user-password Combine1275317 --db-subnet-group-name \$TF_RDS_SUBNET_GROUP_NAME --db-instance-identifier CombineEndpointTestInstance --db-instance-class db.m5.large --allocated-storage 8 --engine mysql --availability-zone us-iso-east-1a"
require_long "delete-db-instance supported type" && require_tf "delete-db-instance supported type" TF_RDS_SUBNET_GROUP_NAME && validate_success "delete-db-instance supported type" "aws rds delete-db-instance --skip-final-snapshot --db-instance-identifier CombineEndpointTestInstance"
[[ "$LONG_TESTS" == "true" && -n "$TF_RDS_SUBNET_GROUP_NAME" ]] && wait_rds_deleted instance CombineEndpointTestInstance

log ""
log "########################"
log "# 55. RDS validate rewrite"
log "########################"

validate_rewrite_smart "describe-source-regions" "aws rds describe-source-regions --region-name us-iso-west-1"

log ""
log "########################"
log "# 56. EMR unsupported instance types"
log "########################"

validate_expected_error_match "emr create-cluster with instance-type $UNSUPPORTED_EMR_TYPE_1" "aws emr create-cluster --release-label emr-7.9.0 --instance-type $UNSUPPORTED_EMR_TYPE_1 --use-default-roles" "Instance type '$UNSUPPORTED_EMR_TYPE_1' is not supported."
validate_expected_error_match "emr create-cluster with instance-groups (starts with $UNSUPPORTED_EMR_TYPE_1)" "aws emr create-cluster --release-label emr-7.9.0 --instance-groups InstanceType=$UNSUPPORTED_EMR_TYPE_1,InstanceGroupType=foo,InstanceCount=1 InstanceType=$UNSUPPORTED_EMR_TYPE_2,InstanceGroupType=foo,InstanceCount=1 --use-default-roles" "Instance type '$UNSUPPORTED_EMR_TYPE_1' is not supported."
validate_expected_error_match "emr create-cluster with instance-fleets (starts with $UNSUPPORTED_EMR_TYPE_1)" "aws emr create-cluster --release-label emr-7.9.0 --instance-fleets InstanceFleetType=foo,InstanceTypeConfigs={InstanceType=$UNSUPPORTED_EMR_TYPE_1} InstanceFleetType=foo,InstanceTypeConfigs={InstanceType=$UNSUPPORTED_EMR_TYPE_2} --use-default-roles" "Instance type '$UNSUPPORTED_EMR_TYPE_1' is not supported."

log ""
log "########################"
log "# 57. KMS key policy validation and rewrite coverage"
log "########################"

validate_rewrite_smart "kms create-key" "aws kms create-key --policy '{ \"Version\" : \"2012-10-17\", \"Id\" : \"key-default-1\", \"Statement\" : [ { \"Effect\" : \"Allow\", \"Principal\" : { \"AWS\" : \"arn:aws-iso:iam::663117128738:root\" }, \"Action\" : \"kms:*\", \"Resource\" : \"*\" }, { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"logs.us-east-1.amazonaws.com\" }, \"Action\": [ \"kms:Encrypt*\", \"kms:Decrypt*\", \"kms:ReEncrypt*\", \"kms:GenerateDataKey*\", \"kms:Describe*\" ], \"Resource\": \"*\", \"Condition\": { \"ArnEquals\": { \"kms:EncryptionContext:aws:logs:arn\": \"arn:aws-iso:logs:us-iso-east-1:362835259437:*\" } } } ] }'" "" ".KeyMetadata.KeyId" "KEY_ID"
validate_success "kms put-key-policy 1" "aws kms put-key-policy --key-id $KEY_ID --policy-name default --policy '{ \"Version\" : \"2012-10-17\", \"Id\" : \"key-default-1\", \"Statement\" : [ { \"Sid\": \"Foo\", \"Effect\" : \"Allow\", \"Principal\" : { \"AWS\" : \"arn:aws-iso:iam::663117128738:root\" }, \"Action\" : \"kms:*\", \"Resource\" : \"*\" }, { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"logs.us-east-1.amazonaws.com\" }, \"Action\": [ \"kms:Encrypt*\", \"kms:Decrypt*\", \"kms:ReEncrypt*\", \"kms:GenerateDataKey*\", \"kms:Describe*\" ], \"Resource\": \"*\", \"Condition\": { \"ArnEquals\": { \"kms:EncryptionContext:aws:logs:arn\": \"arn:aws-iso:logs:us-iso-east-1:362835259437:*\" } } } ] }'"
validate_rewrite_smart "kms get-key-policy 1" "aws kms get-key-policy --key-id $KEY_ID --policy-name default"
validate_success "kms put-key-policy 2" "aws kms put-key-policy --key-id $KEY_ID --policy-name default --policy '{ \"Version\" : \"2012-10-17\", \"Id\" : \"key-default-1\", \"Statement\" : [ { \"Effect\" : \"Allow\", \"Principal\" : { \"AWS\":\"arn:aws-iso:iam::663117128738:root\", \"Service\" : \"ec2.c2s.ic.gov\" }, \"Action\" : \"kms:*\", \"Resource\" : \"*\" }, { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"ec2.c2s.ic.gov\" }, \"Action\": [ \"kms:Encrypt*\", \"kms:Decrypt*\", \"kms:ReEncrypt*\", \"kms:GenerateDataKey*\", \"kms:Describe*\", \"kms:List*\" ], \"Resource\": \"*\", \"Condition\": { \"StringEquals\": { \"kms:ViaService\": \"ec2.c2s.ic.gov\" } } } ] }'"
validate_rewrite_smart "kms get-key-policy 2" "aws kms get-key-policy --key-id $KEY_ID --policy-name default"
validate_success "kms put-key-policy 3" "aws kms put-key-policy --key-id $KEY_ID --policy-name default --policy '{ \"Version\" : \"2012-10-17\", \"Id\" : \"key-default-1\", \"Statement\" : [ { \"Effect\" : \"Allow\", \"Principal\" : { \"AWS\":\"arn:aws-iso:iam::663117128738:root\", \"Service\" : \"elasticmapreduce.c2s.ic.gov\" }, \"Action\" : \"kms:*\", \"Resource\" : \"*\" }, { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"elasticmapreduce.c2s.ic.gov\" }, \"Action\": [ \"kms:Encrypt*\", \"kms:Decrypt*\", \"kms:ReEncrypt*\", \"kms:GenerateDataKey*\", \"kms:Describe*\", \"kms:List*\" ], \"Resource\": \"*\", \"Condition\": { \"StringEquals\": { \"kms:ViaService\": \"elasticmapreduce.c2s.ic.gov\" } } } ] }'"
validate_rewrite_smart "kms get-key-policy 3" "aws kms get-key-policy --key-id $KEY_ID --policy-name default"
require_isob "kms put-key-policy 4 (isob region)" && validate_success "kms put-key-policy 4 (isob region)" "aws kms put-key-policy --key-id $KEY_ID --policy-name default --policy '{ \"Version\" : \"2012-10-17\", \"Id\" : \"key-default-1\", \"Statement\" : [ { \"Effect\" : \"Allow\", \"Principal\" : { \"AWS\":\"arn:aws-iso-b:iam::663117128738:root\", \"Service\" : \"ec2.sc2s.sgov.gov\" }, \"Action\" : \"kms:*\", \"Resource\" : \"*\" }, { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"ec2.sc2s.sgov.gov\" }, \"Action\": [ \"kms:Encrypt*\", \"kms:Decrypt*\", \"kms:ReEncrypt*\", \"kms:GenerateDataKey*\", \"kms:Describe*\", \"kms:List*\" ], \"Resource\": \"*\", \"Condition\": { \"StringEquals\": { \"kms:ViaService\": \"ec2.us-isob-east-1.sc2s.sgov.gov\" } } } ] }' --region us-isob-east-1"
require_isob "kms get-key-policy 4 (isob region)" && validate_rewrite_smart "kms get-key-policy 4 (isob region)" "aws kms get-key-policy --key-id $KEY_ID --policy-name default"
require_isob "kms put-key-policy 5 (commercial ec2 test)" && validate_success "kms put-key-policy 5 (commercial ec2 test)" "aws kms put-key-policy --key-id $KEY_ID --policy-name default --policy '{ \"Version\" : \"2012-10-17\", \"Id\" : \"key-default-1\", \"Statement\" : [ { \"Effect\" : \"Allow\", \"Principal\" : { \"AWS\":\"arn:aws-iso-b:iam::663117128738:root\", \"Service\" : \"ec2.amazonaws.com\" }, \"Action\" : \"kms:*\", \"Resource\" : \"*\" }, { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"ec2.amazonaws.com\" }, \"Action\": [ \"kms:Encrypt*\", \"kms:Decrypt*\", \"kms:ReEncrypt*\", \"kms:GenerateDataKey*\", \"kms:Describe*\", \"kms:List*\" ], \"Resource\": \"*\", \"Condition\": { \"StringEquals\": { \"kms:ViaService\": \"ec2.us-isob-east-1.amazonaws.com\" } } } ] }' --region us-isob-east-1"
validate_rewrite_smart "kms get-key-policy 5 (commercial ec2 test)" "aws kms get-key-policy --key-id $KEY_ID --policy-name default"
validate_rewrite_smart "kms create-key" "aws kms create-key --policy '{ \"Version\" : \"2012-10-17\", \"Id\" : \"key-default-1\", \"Statement\" : [ { \"Effect\" : \"Allow\", \"Principal\" : { \"AWS\" : \"arn:aws-iso:iam::663117128738:root\" }, \"Action\" : \"kms:*\", \"Resource\" : \"*\" } ] }'" "" ".KeyMetadata.KeyId" "KEY_ID"
validate_success "kms create-grant" "aws kms create-grant --key-id \$KEY_ID --grantee-principal arn:aws-iso:iam::663117128738:role/Combine-${SHARD}-TS-WLDEVELOPER --operations Decrypt --constraints EncryptionContextSubset={Department=IT} --retiring-principal arn:aws-iso:iam::663117128738:root" "__nonempty__"
validate_rewrite_smart "kms list-grants" "aws kms list-grants --key-id \$KEY_ID" "" ".Grants[0].GrantId" "GRANT_ID"
validate_success "kms retire-grant" "aws kms retire-grant --key-id arn:aws-iso:kms:us-iso-east-1:663117128738:key/\$KEY_ID --grant-id \$GRANT_ID"
validate_success "kms create-alias" "aws kms create-alias --alias-name alias/Test --target-key-id \$KEY_ID"
validate_success "kms list-aliases" "aws kms list-aliases" "alias/Test"
validate_success "kms delete-alias" "aws kms delete-alias --alias-name alias/Test"
validate_rewrite_smart "kms encrypt (file input)" "aws kms encrypt --key-id \$KEY_ID --plaintext fileb://test.encrypt" "" ".CiphertextBlob" "ENCRYPTED_BLOB"
validate_success "kms encrypt + save output to file" "aws kms encrypt --key-id \$KEY_ID --plaintext fileb://test.encrypt --output text --query CiphertextBlob | base64 --decode > test.decrypt"
validate_success "kms decrypt + save output to file" "aws kms decrypt --key-id \$KEY_ID --ciphertext-blob fileb://test.decrypt --output text --query Plaintext | base64 --decode > test.unencrypted"

# Check that decrypted output matches original input LRM maybe circle back to this.. I hate having specific checks..
if cmp -s test.encrypt test.unencrypted; then
  echo "✅ KMS encrypt/decrypt roundtrip succeeded (files match)"
  record_pass
else
  echo "❌ KMS encrypt/decrypt roundtrip failed (files do NOT match)"
  record_fail "KMS encrypt/decrypt roundtrip" "decrypted output does not match original — check KMS key permissions or ciphertext corruption"
fi

validate_rewrite_smart "kms schedule-key-deletion" "aws kms schedule-key-deletion --key-id \$KEY_ID --pending-window-in-days 7 --endpoint-url https://kms.us-iso-east-1.c2s.ic.gov" "" ".KeyId"

log ""
log "########################"
log "# 58. SQS create + delete queue and DLQ source listing"
log "########################"

validate_rewrite_smart "sqs create-queue (returns URL)" "aws sqs create-queue --queue-name combine-endpoints-create-test" "" ".QueueUrl" "TEST_QUEUE_URL"
validate_rewrite_smart "sqs list-queues" "aws sqs list-queues"
validate_rewrite_smart "sqs get-queue-url" "aws sqs get-queue-url --queue-name combine-endpoints-create-test"
validate_success "sqs delete-queue" "aws sqs delete-queue --queue-url \$TEST_QUEUE_URL"
require_tf "sqs list-dead-letter-source-queues" TF_SQS_REDRIVE_QUEUE_URL && validate_success "sqs list-dead-letter-source-queues" "aws sqs list-dead-letter-source-queues --queue-url $TF_SQS_REDRIVE_QUEUE_URL"

log ""
log "########################"
log "# 59. EC2 describe-instance-type-offerings plus verify unsuported type is not returned"
log "########################"

validate_rewrite_smart "ec2 describe-instance-type-offerings (default region)" "aws ec2 describe-instance-type-offerings"
require_isob "ec2 describe-instance-type-offerings (ISOB region)" && validate_rewrite_smart "ec2 describe-instance-type-offerings (ISOB region)" "aws ec2 describe-instance-type-offerings --region us-isob-east-1"
validate_instance_type_absent_grep "instance-type-offerings (r7g.large filtered out)" "aws ec2 describe-instance-type-offerings --filters Name=instance-type,Values=r7g.large,t3.nano" "r7g.large"

log ""
log "########################"
log "# 60. Reserved Instance Offerings – filter by instance type"
log "########################"

validate_success "describe-reserved-instances-offerings (m5.large – should return data)" "aws ec2 describe-reserved-instances-offerings --availability-zone us-iso-east-1a --filters Name=availability-zone,Values=us-iso-east-1a --instance-type m5.large" "__nonempty__"
validate_instance_type_absent_grep "describe-reserved-instances-offerings (m6a.large – should not appear)" "aws ec2 describe-reserved-instances-offerings --availability-zone us-iso-east-1a --filters Name=availability-zone,Values=us-iso-east-1a --instance-type m6a.large" "m6a.large"

log ""
log "########################"
log "# 61. EC2 Invalid Instance Type – should fail with expected error"
log "########################"

validate_expected_error_match "ec2 run-instances with invalid instance type" "aws ec2 run-instances --instance-type m7a.large" "The following supplied instance types do not exist"
validate_expected_error_match "ec2 modify-instance-attribute (Value=...)" "aws ec2 modify-instance-attribute --instance-id i-12345678901234567 --instance-type Value=m7a.large" "The following supplied instance types do not exist"
validate_expected_error_match "ec2 modify-instance-attribute (--attribute ... --value)" "aws ec2 modify-instance-attribute --instance-id i-12345678901234567 --attribute instanceType --value m7a.large" "The following supplied instance types do not exist"
validate_expected_error_match "ec2 create-launch-template (invalid instance type)" "aws ec2 create-launch-template --launch-template-name Test --launch-template-data InstanceType=m7a.large" "The following supplied instance types do not exist"

log ""
log "########################"
log "# 62. Elasticache invalid node types – should fail with expected errors"
log "########################"

validate_expected_error_match "elasticache create-replication-group (invalid node type)" "aws elasticache create-replication-group --cache-node-type cache.r7g.large --replication-group-id foo --replication-group-description bar" "Cache Node Type specified is not a valid node type."
validate_expected_error_match "elasticache create-cache-cluster (invalid node type)" "aws elasticache create-cache-cluster --cache-node-type cache.r7g.large --cache-cluster-id foo --engine redis" "Invalid Cache Node Type:"
validate_expected_error_match "elasticache modify-replication-group (invalid node type)" "aws elasticache modify-replication-group --cache-node-type cache.r7g.large --replication-group-id foo" "Cache Node Type specified is not a valid node type."
validate_expected_error_match "elasticache modify-cache-cluster (invalid node type)" "aws elasticache modify-cache-cluster --cache-node-type cache.r7g.large --cache-cluster-id foo" "Invalid Cache Node Type:"

log ""
log "########################"
log "# 63. CloudWatch alarm creation, tagging, and cleanup – verify rewrites and deletion"
log "########################"

require_tf "cloudwatch put-metric-alarm (create alarm)" TF_SNS_TOPIC_2_ARN TF_CLOUDWATCH_ALARM_NAME && validate_success "cloudwatch put-metric-alarm (create alarm)" "aws cloudwatch put-metric-alarm --alarm-name CombineTest${RUN_SUFFIX} --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 300 --threshold 70 --comparison-operator GreaterThanThreshold --dimensions Name=InstanceId,Value=i-12345678912 --evaluation-periods 2 --ok-actions $TF_SNS_TOPIC_2_ARN --insufficient-data-actions $TF_SNS_TOPIC_2_ARN --alarm-actions $TF_SNS_TOPIC_2_ARN --unit Percent"
require_tf "cloudwatch describe-alarms (rewrite check)" TF_SNS_TOPIC_2_ARN TF_CLOUDWATCH_ALARM_NAME && validate_rewrite_smart "cloudwatch describe-alarms (rewrite check)" "aws cloudwatch describe-alarms --action-prefix $TF_SNS_TOPIC_2_ARN"
require_tf "cloudwatch list-tags-for-resource (no tags expected)" TF_SNS_TOPIC_2_ARN TF_CLOUDWATCH_ALARM_NAME && validate_success "cloudwatch list-tags-for-resource (no tags expected)" "aws cloudwatch list-tags-for-resource --resource-arn arn:aws-iso:cloudwatch:us-iso-east-1:663117128738:alarm:$TF_CLOUDWATCH_ALARM_NAME"
require_tf "cloudwatch delete-alarms" TF_SNS_TOPIC_2_ARN TF_CLOUDWATCH_ALARM_NAME && validate_success "cloudwatch delete-alarms" "aws cloudwatch delete-alarms --alarm-names CombineTest${RUN_SUFFIX}"
require_tf "cloudwatch describe-alarms (should be empty after delete)" TF_SNS_TOPIC_2_ARN TF_CLOUDWATCH_ALARM_NAME && validate_rewrite_smart "cloudwatch describe-alarms (should be empty after delete)" "aws cloudwatch describe-alarms --action-prefix $TF_SNS_TOPIC_2_ARN"

# Section 64 removed — KMS FIPS rewrite is already covered by section 27

log ""
log "########################"
log "# 65. CloudWatch Events rule and bus lifecycle"
log "########################"

validate_rewrite_smart "events create-event-bus" "aws events create-event-bus --name CombineTest"
validate_rewrite_smart "events describe-event-bus" "aws events describe-event-bus --name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest"
require_tf "events put-rule" TF_IAM_ROLE_CW_EVENTS_ARN TF_LAMBDA_FUNCTION_ARN && validate_rewrite_smart "events put-rule" "aws events put-rule --name CombineTest --event-pattern '{\"source\":[\"com.mycompany.myapp\"]}' --role-arn $TF_IAM_ROLE_CW_EVENTS_ARN --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest"
validate_rewrite_smart "events describe-rule" "aws events describe-rule --name CombineTest --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest"
require_tf "events put-targets" TF_IAM_ROLE_CW_EVENTS_ARN TF_LAMBDA_FUNCTION_ARN && validate_success "events put-targets" "aws events put-targets --rule CombineTest --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest --targets Id=Foo,Arn=$TF_LAMBDA_FUNCTION_ARN"
validate_rewrite_smart "events list-targets-by-rule" "aws events list-targets-by-rule --rule CombineTest --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest"
validate_success "events put-events (events.json)" "aws events put-events --entries file://events.json"
validate_success "events remove-targets" "aws events remove-targets --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest --rule CombineTest --ids Foo"
validate_success "events delete-rule" "aws events delete-rule --name CombineTest --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest"
validate_success "events delete-event-bus" "aws events delete-event-bus --name CombineTest"

log ""
log "########################"
log "# 66. CloudWatch Logs + disallowed KMS key usage"
log "########################"

require_tf "logs associate-kms-key with disallowed KMS key" TF_KMS_KEY_ARN && validate_expected_error_match "logs associate-kms-key with disallowed KMS key" "aws logs associate-kms-key --log-group-name Foo --kms-key-id $TF_KMS_KEY_ARN" "is not allowed to be used with"
require_tf "logs create-log-group with disallowed KMS key" TF_KMS_KEY_ARN && validate_expected_error_match "logs create-log-group with disallowed KMS key" "aws logs create-log-group --log-group-name KmsKeyTest --kms-key-id $TF_KMS_KEY_ARN" "is not allowed to be used with"

log ""
log "########################"
log "# 67. CloudWatch Logs - describe log groups and streams"
log "########################"

validate_rewrite_smart "logs describe-log-groups" "aws logs describe-log-groups --max-items 5"
validate_rewrite_smart "logs describe-log-streams" "aws logs describe-log-streams --log-group-name $ENDPOINT_LOG_GROUP --max-items 5"

log ""
log "########################"
log "# 68. Autoscaling group and notification validation"
log "########################"

require_isob "autoscaling describe-auto-scaling-groups" && validate_rewrite_smart "autoscaling describe-auto-scaling-groups" "aws autoscaling describe-auto-scaling-groups --region us-isob-east-1"
require_isob "autoscaling describe-auto-scaling-instances" && validate_rewrite_smart "autoscaling describe-auto-scaling-instances" "aws autoscaling describe-auto-scaling-instances --region us-isob-east-1"
require_tf "autoscaling put-notification-configuration" TF_SNS_TOPIC_2_ARN && validate_success "autoscaling put-notification-configuration" "aws autoscaling put-notification-configuration --auto-scaling-group-name ${SHARD}-Combine-ASG-Endpoints --topic-arn $TF_SNS_TOPIC_2_ARN --notification-types autoscaling:EC2_INSTANCE_LAUNCH"
require_tf "autoscaling delete-notification-configuration" TF_SNS_TOPIC_2_ARN && validate_success "autoscaling delete-notification-configuration" "aws autoscaling delete-notification-configuration --auto-scaling-group-name ${SHARD}-Combine-ASG-Endpoints --topic-arn $TF_SNS_TOPIC_2_ARN"

log ""
log "########################"
log "# 69. Launch Template with ARNs and rewrite validation"
log "########################"

validate_rewrite_smart "ec2 create-launch-template" "aws ec2 create-launch-template --launch-template-name EndpointsTest --version-description V1 --launch-template-data '{\"Placement\":{\"AvailabilityZone\":\"us-iso-east-1a\", \"HostResourceGroupArn\":\"arn:aws-iso:resource-groups:us-iso-east-1:663117128738:group/Test\"}, \"CapacityReservationSpecification\":{\"CapacityReservationTarget\":{\"CapacityReservationResourceGroupArn\":\"arn:aws-iso:resource-groups:us-iso-east-1:663117128738:group/Test\"}}, \"NetworkInterfaces\":[{\"AssociatePublicIpAddress\":true,\"DeviceIndex\":0,\"Ipv6AddressCount\":1,\"SubnetId\":\"subnet-0dcfd5cd50ad0ca6c\"}],\"IamInstanceProfile\":{\"Arn\":\"arn:aws-iso:iam::663117128738:instance-profile/Combine-Policy-TSInstanceProfileWLDEVELOPER-lSJ9VTfXTkEb\"}, \"BlockDeviceMappings\":[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{ \"Encrypted\":\"true\", \"KmsKeyId\":\"arn:aws-iso:kms:us-iso-east-1:663117128738:key/778b96a8-e41c-4a4d-a09e-368526bbf0d4\", \"DeleteOnTermination\":true }}],\"ImageId\":\"ami-06a0cd9728546d178\",\"InstanceType\":\"t3.micro\"}'"
validate_rewrite_smart "ec2 describe-launch-templates" "aws ec2 describe-launch-templates --launch-template-names EndpointsTest"
validate_rewrite_smart "ec2 describe-launch-template-versions" "aws ec2 describe-launch-template-versions --launch-template-name EndpointsTest --versions 1"
validate_success "ec2 delete-launch-template" "aws ec2 delete-launch-template --launch-template-name EndpointsTest"

log ""
log "########################"
log "# 70. Launch Template with unsupported HttpProtocol metadata option"
log "########################"

validate_expected_error_match "ec2 create-launch-template with unsupported HttpProtocol" "aws ec2 create-launch-template --launch-template-name Endpoints --launch-template-data '{\"MetadataOptions\":{\"HttpEndpoint\":\"enabled\", \"HttpPutResponseHopLimit\":\"1\", \"HttpTokens\":\"optional\", \"HttpProtocolIpv6\":\"disabled\", \"InstanceMetadataTags\":\"disabled\"}, \"NetworkInterfaces\":[{\"DeviceIndex\":0,\"AssociatePublicIpAddress\":true,\"Groups\":[\"sg-07b37d46d6465878b\"],\"DeleteOnTermination\":true}],\"ImageId\":\"ami-01eccbf80522b562b\",\"InstanceType\":\"t3.nano\",\"TagSpecifications\":[{\"ResourceType\":\"instance\",\"Tags\":[{\"Key\":\"environment\",\"Value\":\"Test\"},{\"Key\":\"purpose\",\"Value\":\"Test\"}]},{\"ResourceType\":\"volume\",\"Tags\":[{\"Key\":\"environment\",\"Value\":\"Test\"},{\"Key\":\"cost-center\",\"Value\":\"Test\"}]}],\"BlockDeviceMappings\":[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":16}}]}'" "Specifying HttpProtocol metadata options for an instance is not supported in this region"

log ""
log "########################"
log "# 71. Lambda create-function fails due to invalid role ARN"
log "########################"

validate_expected_error_match "lambda create-function with invalid role ARN" "aws lambda create-function --function-name foo --role foo --vpc-config SubnetIds=subnet-aaaaaaaa,subnet-bbbbbbbb,subnet-cccccccc,SecurityGroupIds=foo" "Member must satisfy regular expression pattern: arn:"

log ""
log "########################"
log "# 72. Lambda create-function fails due to missing VPC configuration"
log "########################"

validate_expected_error_match "lambda create-function with empty vpc-config" "aws lambda create-function --function-name foo --role foo --vpc-config {}" "attempted to create/modify Lambda Function without a VPC Configuration"
validate_expected_error_match "lambda create-function without vpc-config" "aws lambda create-function --function-name foo --role foo" "attempted to create/modify Lambda Function without a VPC Configuration"
validate_expected_error_match "lambda update-function-configuration with empty VPC config" "aws lambda update-function-configuration --function-name foo --vpc-config {}" "attempted to create/modify Lambda Function without a VPC Configuration"

log ""
log "########################"
log "# 73. Lambda Code Signing Config – create, get, delete"
log "########################"

validate_rewrite_smart "lambda create-code-signing-config" "aws lambda create-code-signing-config --allowed-publishers SigningProfileVersionArns=arn:aws-iso:iam::663117128738:user/test-combine-endpoints-user" "" ".CodeSigningConfig.CodeSigningConfigArn" "CODE_SIGNING_ARN"
validate_rewrite_smart "lambda get-code-signing-config" "aws lambda get-code-signing-config --code-signing-config-arn \$CODE_SIGNING_ARN"
validate_success "lambda delete-code-signing-config" "aws lambda delete-code-signing-config --code-signing-config-arn \$CODE_SIGNING_ARN"
require_tf "lambda add-permission from S3 arn" TF_LAMBDA_FUNCTION_NAME && validate_rewrite_smart "lambda add-permission from S3 arn" "aws lambda add-permission --function-name \$TF_LAMBDA_FUNCTION_NAME --statement-id CliTestArn --action lambda:InvokeFunction --principal s3.amazonaws.com --source-arn arn:aws-iso:s3:::combine-devops-370881201289"
require_tf "lambda add-permission from EMR" TF_LAMBDA_FUNCTION_NAME && validate_rewrite_smart "lambda add-permission from EMR" "aws lambda add-permission --function-name \$TF_LAMBDA_FUNCTION_NAME --statement-id CliTestServicePrincipal --action lambda:InvokeFunction --principal elasticmapreduce.c2s.ic.gov"
require_tf "lambda add-permission from EC2 optional" TF_LAMBDA_FUNCTION_NAME && validate_rewrite_smart "lambda add-permission from EC2 optional" "aws lambda add-permission --function-name \$TF_LAMBDA_FUNCTION_NAME --statement-id CliTestServicePrincipalOptional --action lambda:InvokeFunction --principal ec2.c2s.ic.gov"
require_tf "lambda get-policy" TF_LAMBDA_FUNCTION_NAME && validate_rewrite_smart "lambda get-policy" "aws lambda get-policy --function-name \$TF_LAMBDA_FUNCTION_NAME"
require_tf "lambda create-alias" TF_LAMBDA_FUNCTION_ARN && validate_rewrite_smart "lambda create-alias" "aws lambda create-alias --function-name \$TF_LAMBDA_FUNCTION_ARN --name TestAlias --function-version '\$LATEST'"
require_tf "lambda get-alias" TF_LAMBDA_FUNCTION_ARN && validate_rewrite_smart "lambda get-alias" "aws lambda get-alias --function-name \$TF_LAMBDA_FUNCTION_ARN --name TestAlias"
require_tf "lambda delete-alias" TF_LAMBDA_FUNCTION_ARN && validate_success "lambda delete-alias" "aws lambda delete-alias --function-name \$TF_LAMBDA_FUNCTION_ARN --name TestAlias"
require_tf "lambda remove-permission (S3 arn)" TF_LAMBDA_FUNCTION_NAME && validate_success "lambda remove-permission (S3 arn)" "aws lambda remove-permission --function-name \$TF_LAMBDA_FUNCTION_NAME --statement-id CliTestArn"
require_tf "lambda remove-permission (EMR)" TF_LAMBDA_FUNCTION_NAME && validate_success "lambda remove-permission (EMR)" "aws lambda remove-permission --function-name \$TF_LAMBDA_FUNCTION_NAME --statement-id CliTestServicePrincipal"
require_tf "lambda remove-permission (EC2 optional)" TF_LAMBDA_FUNCTION_NAME && validate_success "lambda remove-permission (EC2 optional)" "aws lambda remove-permission --function-name \$TF_LAMBDA_FUNCTION_NAME --statement-id CliTestServicePrincipalOptional"
validate_rewrite_smart "lambda list-functions ALL" "aws lambda list-functions --function-version ALL"
validate_rewrite_smart "lambda list-functions master region" "aws lambda list-functions --master-region us-iso-east-1 --function-version ALL"

log ""
log "########################"
log "# 74. EC2 Run + Terminate Instance"
log "########################"

validate_rewrite_smart "ec2 run-instances" "aws ec2 run-instances --image-id ami-0d5eff06f840b45e9 --subnet-id $SUBNET_1 --instance-type t3.nano --placement AvailabilityZone=us-iso-east-1a" "" ".Instances[0].InstanceId" "EC2_INSTANCE_ID"
validate_success "ec2 terminate-instances" "aws ec2 terminate-instances --instance-ids \$EC2_INSTANCE_ID" "shutting-down"

log ""
log "########################"
log "# 75. SNS topic create/get/set/delete (rewrites and success)"
log "########################"

validate_rewrite_smart "sns create-topic" "aws sns create-topic --name Test --attributes file://test_sns.json" "" ".TopicArn" "SNS_TOPIC_ARN"
validate_rewrite_smart "sns get-topic-attributes (after create)" "aws sns get-topic-attributes --topic-arn \$SNS_TOPIC_ARN"
validate_success "sns set-topic-attributes" "aws sns set-topic-attributes --topic-arn \$SNS_TOPIC_ARN --attribute-name Policy --attribute-value '{\"Version\":\"2008-10-17\",\"Id\":\"__default_policy_ID\",\"Statement\":[{\"Sid\":\"__default_statement_ID\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"*\"},\"Action\":[\"SNS:GetTopicAttributes\",\"SNS:SetTopicAttributes\",\"SNS:AddPermission\",\"SNS:RemovePermission\",\"SNS:DeleteTopic\",\"SNS:Subscribe\",\"SNS:ListSubscriptionsByTopic\",\"SNS:Publish\"],\"Resource\":\"\$SNS_TOPIC_ARN\",\"Condition\":{\"StringEquals\":{\"AWS:SourceOwner\":\"663117128738\"}}}]}'"
validate_rewrite_smart "sns get-topic-attributes (after set)" "aws sns get-topic-attributes --topic-arn \$SNS_TOPIC_ARN"
validate_success "sns delete-topic" "aws sns delete-topic --topic-arn \$SNS_TOPIC_ARN"
validate_rewrite_smart "sqs create-queue (Test2)" "aws sqs create-queue --queue-name Test2"
validate_success "sqs receive-message (queue URL)" "aws sqs receive-message --queue-url https://sqs.us-iso-east-1.c2s.ic.gov/663117128738/Test2"
validate_success "sqs receive-message (queue name)" "aws sqs receive-message --queue-url Test2"
validate_expected_error_match "sqs receive-message (commercial URL)" "aws sqs receive-message --queue-url https://sqs.us-east-1.amazonaws.com/663117128738/Test2" "An error occurred"
validate_expected_error_match "sqs receive-message (ISO region, commercial domain)" "aws sqs receive-message --queue-url https://sqs.us-iso-east-1.amazonaws.com/663117128738/Test2" "An error occurred"
validate_expected_error_match "sqs receive-message (commercial region, ISO domain)" "aws sqs receive-message --queue-url https://sqs.us-east-1.c2s.ic.gov/663117128738/Test2" "An error occurred"
validate_rewrite_smart "sns create-topic (Test2)" "aws sns create-topic --name Test2"
validate_success "sns tag-resource" "aws sns tag-resource --resource-arn arn:aws-iso:sns:us-iso-east-1:663117128738:Test2 --tags Key=Test,Value=Test"
validate_rewrite_smart "sns list-topics" "aws sns list-topics"
validate_success "sns untag-resource" "aws sns untag-resource --resource-arn arn:aws-iso:sns:us-iso-east-1:663117128738:Test2 --tag-keys Test"
validate_rewrite_smart "sns subscribe to SQS queue" "aws sns subscribe --topic-arn arn:aws-iso:sns:us-iso-east-1:663117128738:Test2 --protocol sqs --notification-endpoint arn:aws-iso:sqs:us-iso-east-1:663117128738:Test2" "" ".SubscriptionArn" "SUBSCRIPTION_ARN"
validate_rewrite_smart "sns list-subscriptions" "aws sns list-subscriptions"
validate_rewrite_smart "sns list-subscriptions-by-topic" "aws sns list-subscriptions-by-topic --topic-arn arn:aws-iso:sns:us-iso-east-1:663117128738:Test2"
validate_success "sns publish (target-arn)" "aws sns publish --target-arn arn:aws-iso:sns:us-iso-east-1:663117128738:Test2 --message {}"
validate_success "sns publish (topic-arn)" "aws sns publish --topic-arn arn:aws-iso:sns:us-iso-east-1:663117128738:Test2 --message {}"
validate_success "sns unsubscribe" "aws sns unsubscribe --subscription-arn \$SUBSCRIPTION_ARN"
validate_success "sns delete-topic (Test2)" "aws sns delete-topic --topic-arn arn:aws-iso:sns:us-iso-east-1:663117128738:Test2"
validate_success "sqs delete-queue (Test2)" "aws sqs delete-queue --queue-url https://sqs.us-iso-east-1.c2s.ic.gov/663117128738/Test2"

log ""
log "########################"
log "# 76. EFS create + policy and access point validation"
log "########################"

validate_rewrite_smart "efs create-file-system" "aws efs create-file-system --performance-mode generalPurpose --throughput-mode bursting" "" ".FileSystemId" "FS_ID"
[[ -n "${FS_ID:-}" ]] && { log "⏳ Waiting for EFS file system $FS_ID to become available..."; wait_until 300 "[[ \$(aws efs describe-file-systems --file-system-id $FS_ID --query 'FileSystems[0].LifeCycleState' --output text) == available ]]" || log "⚠️  EFS file system $FS_ID did not become available in time"; }
validate_rewrite_smart "efs put-file-system-policy" "aws efs put-file-system-policy --file-system-id \$FS_ID --policy file://efs-policy.json"
validate_rewrite_smart "efs describe-file-systems" "aws efs describe-file-systems"
validate_rewrite_smart "efs describe-file-system-policy" "aws efs describe-file-system-policy --file-system-id \$FS_ID"
validate_success "efs describe-access-points" "aws efs describe-access-points"
validate_success "efs delete-file-system" "aws efs delete-file-system --file-system-id \$FS_ID"

log ""
log "########################"
log "# 77. STS assume-role rewrite validation"
log "########################"

validate_rewrite_smart "sts assume-role (us-iso)" "aws sts assume-role --role-arn arn:aws-iso:iam::663117128738:role/Combine-${SHARD}-TS-WLDEVELOPER --role-session-name Test"
require_isob "sts assume-role (us-isob)" && validate_rewrite_smart "sts assume-role (us-isob)" "aws sts assume-role --role-arn arn:aws-iso-b:iam::663117128738:role/Combine-S-WLDEVELOPER --role-session-name Test" "us-isob-east-1"

log ""
log "########################"
log "# 78. App Autoscaling rewrite validation"
log "########################"

validate_rewrite_smart "application-autoscaling describe-scalable-targets" "aws application-autoscaling describe-scalable-targets --service-namespace dynamodb"

log ""
log "########################"
log "# 79. IAM policy create/delete with rewritten EFS ARNs"
log "########################"

validate_rewrite_smart "iam create-policy (us-iso)" "aws iam create-policy --policy-name Test --policy-document '{\"Statement\":[{\"Action\":[\"elasticfilesystem:DescribeMountTargets\",\"elasticfilesystem:ClientWrite\",\"elasticfilesystem:ClientRootAccess\",\"elasticfilesystem:ClientMount\"],\"Effect\":\"Allow\",\"Resource\":\"arn:aws-iso:elasticfilesystem:us-iso-east-1:123456789123:file-system/fs-11111111111111111\",\"Sid\":\"AllowRW\"}],\"Version\":\"2012-10-17\"}'"
validate_success "iam delete-policy (us-iso)" "aws iam delete-policy --policy-arn arn:aws-iso:iam::663117128738:policy/Test"
require_isob "iam create-policy (us-isob)" && validate_rewrite_smart "iam create-policy (us-isob)" "aws iam create-policy --policy-name Test --policy-document '{\"Statement\":[{\"Action\":[\"elasticfilesystem:DescribeMountTargets\",\"elasticfilesystem:ClientWrite\",\"elasticfilesystem:ClientRootAccess\",\"elasticfilesystem:ClientMount\"],\"Effect\":\"Allow\",\"Resource\":\"arn:aws-iso-b:elasticfilesystem:us-isob-east-1:123456789123:file-system/fs-11111111111111111\",\"Sid\":\"AllowRW\"}],\"Version\":\"2012-10-17\"}'" "us-isob-east-1"
require_isob "iam delete-policy (us-isob)" && validate_success "iam delete-policy (us-isob)" "aws iam delete-policy --policy-arn arn:aws-iso-b:iam::663117128738:policy/Test --region us-isob-east-1"

log ""
log "########################"
log "# 80. IAM policy create/delete with rewritten EFS ARNs"
log "########################"

validate_rewrite_smart "iam create-role with mixed service principals" "aws iam create-role --role-name CombineTestServicePrincipal${RUN_SUFFIX} --assume-role-policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"Service\": [ \"ec2.c2s.ic.gov\", \"elasticmapreduce.c2s.ic.gov\", \"rds.c2s.ic.gov\", \"elasticfilesystem.amazonaws.com\" ] }, \"Action\": \"sts:AssumeRole\" } ] }'"
validate_success "iam get-role (elasticfilesystem.amazonaws.com not rewritten)" "aws iam get-role --role-name CombineTestServicePrincipal${RUN_SUFFIX}" "elasticfilesystem.amazonaws.com"
validate_success "iam delete-role" "aws iam delete-role --role-name CombineTestServicePrincipal${RUN_SUFFIX}"

log ""
log "########################"
log "# 81. IAM role creation with rewritten service principals"
log "########################"

validate_rewrite_smart "iam create-role with rewritten service principals" "aws iam create-role --role-name CombineTestServicePrincipal${RUN_SUFFIX} --assume-role-policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"Service\": [ \"elasticmapreduce.c2s.ic.gov\" ] }, \"Action\": \"sts:AssumeRole\" } ] }'"
validate_rewrite_smart "iam get-role with rewritten service principals" "aws iam get-role --role-name CombineTestServicePrincipal${RUN_SUFFIX}" "" ".Role.AssumeRolePolicyDocument.Statement[0].Principal.Service[]"
validate_success "iam delete-role" "aws iam delete-role --role-name CombineTestServicePrincipal${RUN_SUFFIX}"

log ""
log "########################"
log "# 82. EKS – rewriter and filter verification"
log "# Set EKS_REGION (and optionally EKS_CLUSTER) to run this section."
log "########################"

if [[ -z "$EKS_REGION" ]]; then
  log "⏭️  Skipping EKS section (EKS_REGION not set)"
  record_skip
else
  # Derive expected emulated partition from the region prefix
  case "$EKS_REGION" in
    us-iso-*)   EKS_EXP_PARTITION="aws-iso"    ;;
    us-isob-*)  EKS_EXP_PARTITION="aws-iso-b"  ;;
    us-gov-*)   EKS_EXP_PARTITION="aws-us-gov" ;;
    eusc-*)     EKS_EXP_PARTITION="aws-eusc"   ;;
    *)          EKS_EXP_PARTITION="aws"        ;;
  esac

  EKS_AWS="aws --region $EKS_REGION"
  log "region=$EKS_REGION  cluster=$EKS_CLUSTER  expected-partition=$EKS_EXP_PARTITION"

  # --- Response rewriter (host -> emulated) ---
  log ""
  log "--- describe-cluster: response rewriter ---"
  if ! eks_run $EKS_AWS eks describe-cluster --name "$EKS_CLUSTER"; then
    log "❌ describe-cluster failed; skipping remaining EKS tests"
  else
    CLUSTER_JSON="$RUN_OUT"
    eks_q() { echo "$CLUSTER_JSON" | jq -r "$1"; }

    eks_check "cluster.arn"                   "$(eks_q '.cluster.arn')"                                          arn
    eks_check "cluster.roleArn (IAM)"         "$(eks_q '.cluster.roleArn')"                                      arn-global
    eks_check "encryptionConfig keyArn (KMS)" "$(eks_q '.cluster.encryptionConfig[0].provider.keyArn // empty')" arn

    eks_note "identity.oidc.issuer (expected host/commercial, not emulated) = $(eks_q '.cluster.identity.oidc.issuer // empty')"
    eks_note "cluster.endpoint (expected host/commercial, not emulated)      = $(eks_q '.cluster.endpoint // empty')"

    log ""
    log "--- nodegroups: response rewriter ---"
    if eks_run $EKS_AWS eks list-nodegroups --cluster-name "$EKS_CLUSTER"; then
      NGS="$(echo "$RUN_OUT" | jq -r '.nodegroups[]?')"
      if [[ -z "$NGS" ]]; then eks_skip "no nodegroups on $EKS_CLUSTER"; fi
      for NG in $NGS; do
        if eks_run $EKS_AWS eks describe-nodegroup --cluster-name "$EKS_CLUSTER" --nodegroup-name "$NG"; then
          NG_JSON="$RUN_OUT"
          eks_check "nodegroup[$NG].nodegroupArn" "$(echo "$NG_JSON" | jq -r '.nodegroup.nodegroupArn')" arn
          eks_check "nodegroup[$NG].nodeRole"     "$(echo "$NG_JSON" | jq -r '.nodegroup.nodeRole')"     arn-global
        fi
      done
    fi

    log ""
    log "--- addons: response rewriter ---"
    if eks_run $EKS_AWS eks list-addons --cluster-name "$EKS_CLUSTER"; then
      ADDONS="$(echo "$RUN_OUT" | jq -r '.addons[]?')"
      if [[ -z "$ADDONS" ]]; then eks_skip "no addons on $EKS_CLUSTER"; fi
      for A in $ADDONS; do
        if eks_run $EKS_AWS eks describe-addon --cluster-name "$EKS_CLUSTER" --addon-name "$A"; then
          A_JSON="$RUN_OUT"
          eks_check "addon[$A].addonArn"              "$(echo "$A_JSON" | jq -r '.addon.addonArn')"                       arn
          eks_check "addon[$A].serviceAccountRoleArn" "$(echo "$A_JSON" | jq -r '.addon.serviceAccountRoleArn // empty')" arn-global
        fi
      done
    fi

    # Raw leak scan: nothing in the cluster body should carry the host partition
    log ""
    log "--- raw leak scan (no host 'arn:aws:' when emulated partition differs) ---"
    if [[ "$EKS_EXP_PARTITION" != "aws" ]]; then
      if echo "$CLUSTER_JSON" | grep -q 'arn:aws:'; then
        eks_bad "host partition 'arn:aws:' leaked in describe-cluster body:"
        echo "$CLUSTER_JSON" | grep -o 'arn:aws:[^"]*' | sort -u | sed 's/^/        /'
      else
        eks_ok "no 'arn:aws:' leak in describe-cluster body"
      fi
    else
      eks_skip "emulated partition is commercial; leak scan N/A"
    fi

    # --- Request rewriter (emulated -> host) ---
    log ""
    log "--- list-tags-for-resource: request rewriter (emulated ARN accepted on input) ---"
    CLUSTER_ARN="$(eks_q '.cluster.arn')"
    if eks_run $EKS_AWS eks list-tags-for-resource --resource-arn "$CLUSTER_ARN"; then
      eks_ok "emulated ARN accepted as input and round-tripped: $CLUSTER_ARN"
    else
      eks_bad "list-tags-for-resource rejected the emulated cluster ARN"
    fi

    log ""
    log "--- list-tags-for-resource: commercial ARN must be rejected ---"
    if eks_run $EKS_AWS eks list-tags-for-resource --resource-arn "arn:aws:eks:us-east-1:123456789012:cluster/fake"; then
      eks_bad "commercial ARN was NOT rejected (expected ValidationError)"
    else
      eks_ok "commercial ARN rejected as expected"
    fi

    # --- Rejection / filter rules ---
    log ""
    log "--- filter rules (expect rejection in the applicable partition) ---"
    expect_reject_eks "list-eks-anywhere-subscriptions" $EKS_AWS eks list-eks-anywhere-subscriptions
    expect_reject_eks "list-fargate-profiles"           $EKS_AWS eks list-fargate-profiles --cluster-name "$EKS_CLUSTER"
    expect_reject_eks "create-fargate-profile"          $EKS_AWS eks create-fargate-profile --cluster-name "$EKS_CLUSTER" --fargate-profile-name fake --pod-execution-role-arn fake
    [[ "$EKS_EXP_PARTITION" == "aws-us-gov" ]] && expect_reject_eks "list-capabilities (gov-only)" $EKS_AWS eks list-capabilities --cluster-name "$EKS_CLUSTER"
  fi

  log ""
  log "=== EKS summary: PASS=$EKS_PASS FAIL=$EKS_FAIL SKIP=$EKS_SKIP ==="
fi

#############################
# Sections 83+ complete the coverage of the original manual checklist (combine-endpoints/tests.txt, removed in
# combine-aws a0d371395). Left out on purpose: checks that need Endpoint Server log inspection or Configuration
# Values changed in DynamoDB (RDS version filter, S3 redirect 404), and SageMaker (needs a training role, data and
# images, and creates billable endpoints).
#############################

log ""
log "########################"
log "# 83. S3 path-style addressing – create-bucket and checksums (section 8 covers auto addressing)"
log "########################"

set_s3_addressing_style path
validate_success "s3api create-bucket (path addressing)" "aws s3api create-bucket --bucket combine-test-lc${RUN_SUFFIX,,} --create-bucket-configuration LocationConstraint=us-iso-east-1"
validate_success "s3api delete-bucket (path addressing)" "aws s3api delete-bucket --bucket combine-test-lc${RUN_SUFFIX,,}"
validate_s3 "S3 smallfile.txt (path addressing)" "smallfile.txt" "foo/smallfile.txt" "checksum"
validate_s3 "S3 file.txt (path addressing)" "file.txt" "foo/file.txt" "checksum"
validate_s3 "S3 file++.txt (path addressing)" "file.txt" "foo/bar/baz/file++.txt" "checksum"
validate_s3 "S3 bigfile.txt (path addressing)" "bigfile.txt" "foo/bigfile.txt" "checksum"
require_long "S3 megafile.txt (path addressing)" && validate_s3 "S3 megafile.txt (path addressing)" "megafile.txt" "foo/megafile.txt" "checksum"
set_s3_addressing_style auto
validate_success "s3api create-bucket (auto addressing)" "aws s3api create-bucket --bucket combine-test-lc${RUN_SUFFIX,,} --create-bucket-configuration LocationConstraint=us-iso-east-1"
validate_success "s3api delete-bucket (auto addressing)" "aws s3api delete-bucket --bucket combine-test-lc${RUN_SUFFIX,,}"

log ""
log "########################"
log "# 84. ElastiCache engine versions – unsupported versions rejected, supported ones pass"
log "########################"

validate_expected_error_match "elasticache create-cache-cluster (valkey 8.1)" "aws elasticache create-cache-cluster --cache-cluster-id foo --engine valkey --engine-version 8.1 --cache-node-type cache.m5.large --num-cache-nodes 1" "Cannot find version"
validate_expected_error_match "elasticache create-cache-cluster (redis 7.0)" "aws elasticache create-cache-cluster --cache-cluster-id foo --engine redis --engine-version 7.0 --cache-node-type cache.m5.large --num-cache-nodes 1" "Cannot find version"
validate_expected_error_match "elasticache create-cache-cluster (memcached 1.4.14)" "aws elasticache create-cache-cluster --cache-cluster-id foo --engine memcached --engine-version 1.4.14 --cache-node-type cache.m5.large --num-cache-nodes 1" "Cannot find version"

CACHE_ID="combinetest${RUN_SUFFIX,,}"
if ! require_long "elasticache cache cluster lifecycle"; then
  :
elif [[ -n "$SUBNET_3" ]]; then
  validate_rewrite_smart "elasticache create-cache-subnet-group" "aws elasticache create-cache-subnet-group --cache-subnet-group-name $CACHE_ID --cache-subnet-group-description Foo --subnet-ids $SUBNET_1 $SUBNET_2 $SUBNET_3"
  validate_rewrite_smart "elasticache create-cache-cluster (redis 6.2)" "aws elasticache create-cache-cluster --cache-cluster-id $CACHE_ID --engine redis --engine-version 6.2 --cache-node-type cache.m5.large --num-cache-nodes 1 --az-mode single-az --preferred-availability-zones us-iso-east-1a --cache-subnet-group-name $CACHE_ID"
  validate_expected_error_match "elasticache modify-cache-cluster (7.0 unsupported)" "aws elasticache modify-cache-cluster --cache-cluster-id $CACHE_ID --engine-version 7.0" "Cannot find version"
  # NOTE: Only Combine's validation is under test; AWS may still refuse because the cluster is not "available" yet.
  validate_not_rejected "elasticache modify-cache-cluster (7.1 supported)" "aws elasticache modify-cache-cluster --cache-cluster-id $CACHE_ID --engine-version 7.1"
  log "⏳ Waiting for ElastiCache cluster $CACHE_ID to become available so it can be deleted..."
  aws elasticache wait cache-cluster-available --cache-cluster-id "$CACHE_ID" 2>/dev/null || log "⚠️  ElastiCache cluster $CACHE_ID did not become available in time"
  validate_success "elasticache delete-cache-cluster" "aws elasticache delete-cache-cluster --cache-cluster-id $CACHE_ID"
  log "⏳ Waiting for ElastiCache cluster $CACHE_ID to finish deleting..."
  aws elasticache wait cache-cluster-deleted --cache-cluster-id "$CACHE_ID" 2>/dev/null || log "⚠️  ElastiCache cluster $CACHE_ID did not finish deleting in time"
  validate_success "elasticache delete-cache-subnet-group" "aws elasticache delete-cache-subnet-group --cache-subnet-group-name $CACHE_ID"
else
  echo "🔍 elasticache cache cluster lifecycle: ⏭️ Skipped (needs three Combine Customer Subnets in $VPC_ID)"
  record_skip
fi

validate_success "elasticache describe-cache-engine-versions" "aws elasticache describe-cache-engine-versions" "__nonempty__"
validate_instance_type_absent_grep "elasticache describe-cache-engine-versions (no 7.0)" "aws elasticache describe-cache-engine-versions" '"EngineVersion": "7.0'

log ""
log "########################"
log "# 85. More unsupported APIs – should be rejected by Combine"
log "########################"

validate_expected_error_match "athena list-notebook-metadata" "aws athena list-notebook-metadata --work-group foo" "Combine rejected this AWS API"
validate_expected_error_match "backup create-logically-air-gapped-backup-vault" "aws backup create-logically-air-gapped-backup-vault --backup-vault-name foo --min-retention-days 1 --max-retention-days 7" "Combine rejected this AWS API"
validate_expected_error_match "batch describe-service-environments" "aws batch describe-service-environments" "Combine rejected this AWS API"
validate_expected_error_match "imagebuilder list-lifecycle-policies" "aws imagebuilder list-lifecycle-policies" "Combine rejected this AWS API"
validate_expected_error_match "license-manager list-license-manager-report-generators" "aws license-manager list-license-manager-report-generators" "Combine rejected this AWS API"
validate_expected_error_match "service-quotas list-service-quota-increase-requests-in-template" "aws service-quotas list-service-quota-increase-requests-in-template" "Combine rejected this AWS API"
validate_expected_error_match "textract analyze-id" "aws textract analyze-id --document-pages {}" "Combine rejected this AWS API"
require_isob "datasync describe-location-fsx-open-zfs" && validate_expected_error_match "datasync describe-location-fsx-open-zfs" "aws datasync describe-location-fsx-open-zfs --location-arn foo --region us-isob-east-1" "Combine rejected this AWS API"
require_isob "directconnect associate-mac-sec-key" && validate_expected_error_match "directconnect associate-mac-sec-key" "aws directconnect associate-mac-sec-key --connection-id foo --region us-isob-east-1" "Combine rejected this AWS API"
require_isob "storagegateway describe-cache-report" && validate_expected_error_match "storagegateway describe-cache-report" "aws storagegateway describe-cache-report --cache-report-arn foo --region us-isob-east-1" "Combine rejected this AWS API"

log ""
log "########################"
log "# 86. EC2 / DLM unsupported features – should be rejected by Combine"
log "########################"

validate_expected_error_match "ec2 create-fleet (1)" "aws ec2 create-fleet --type request --launch-template-configs {} --target-capacity-specification {}" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-fleet (2)" "aws ec2 create-fleet --type maintain --launch-template-configs {} --target-capacity-specification {}" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 copy-image" "aws ec2 copy-image --snapshot-copy-completion-duration-minutes 30 --name testCopy --source-image-id ami-123123123123 --source-region us-iso-east-1" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-image-attribute (1)" "aws ec2 modify-image-attribute --image-id ami-123123123123 --attribute launchPermission --operation-type add --organization-arns foo --organizational-unit-arns foo" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-image-attribute (2)" "aws ec2 modify-image-attribute --image-id ami-123123123123 --launch-permission \"Add=[{UserId=foo},{Group=foo},{OrganizationArn=foo}],Remove=[{UserId=foo},{Group=foo}]\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-image-attribute (3)" "aws ec2 modify-image-attribute --image-id ami-123123123123 --launch-permission \"Add=[{UserId=foo},{Group=foo},{OrganizationalUnitArn=foo}],Remove=[{UserId=foo},{Group=foo}]\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-image-attribute (4)" "aws ec2 modify-image-attribute --image-id ami-123123123123 --launch-permission \"Add=[{UserId=foo},{Group=foo}],Remove=[{UserId=foo},{Group=foo},{OrganizationArn=foo}]\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-image-attribute (5)" "aws ec2 modify-image-attribute --image-id ami-123123123123 --launch-permission \"Add=[{UserId=foo},{Group=foo}],Remove=[{UserId=foo},{Group=foo},{OrganizationalUnitArn=foo}]\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-image-attribute (6)" "aws ec2 modify-image-attribute --image-id ami-123123123123 --launch-permission \"Add=[{UserId=foo},{Group=foo}],Remove=[{UserId=foo},{Group=foo}]\"" "attribute item value"
validate_expected_error_match "ec2 create-launch-template" "aws ec2 create-launch-template --launch-template-name foo --launch-template-data ImageId=resolve:ssm:foo" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-launch-template-version" "aws ec2 create-launch-template-version --launch-template-name foo --launch-template-data ImageId=resolve:ssm:foo" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-instance-event-window" "aws ec2 create-instance-event-window" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-instance-maintenance-options" "aws ec2 modify-instance-maintenance-options --instance-id i-12312312312312312 --reboot-migration disabled" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-network-interface" "aws ec2 create-network-interface --subnet-id subnet-123123123123123 --description \"Test\" --ipv4-prefixes Ipv4Prefix=10.0.0.0/28" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 assign-private-ip-addresses" "aws ec2 assign-private-ip-addresses --network-interface-id eni-12312312312312312 --ipv4-prefixes 10.0.0.0/28" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 attach-network-interface" "aws ec2 attach-network-interface --network-interface-id eni-1234567890abcdef0 --instance-id i-1234567890abcdef0 --device-index 1 --ena-srd-specification 'EnaSrdEnabled=true'" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-network-interface-attribute" "aws ec2 modify-network-interface-attribute --network-interface-id eni-1234567890abcdef0 --ena-srd-specification 'EnaSrdEnabled=true'" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-volume" "aws ec2 create-volume --volume-type io1 --multi-attach-enabled --size 100 --iops 2000 --availability-zone us-iso-east-1a" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-volume" "aws ec2 modify-volume --volume-id vol-01234567890abcdef --multi-attach-enabled" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 copy-snapshot" "aws ec2 copy-snapshot --completion-duration-minutes 15 --source-snapshot-id snap-0abcdef1234567890 --source-region us-iso-east-1 --destination-availability-zone us-iso-east-1a" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 cancel-capacity-reservation-fleets" "aws ec2 cancel-capacity-reservation-fleets --capacity-reservation-fleet-ids foo" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-capacity-reservation-fleet" "aws ec2 create-capacity-reservation-fleet --instance-type-specifications {} --total-target-capacity 2" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 run-instances" "aws ec2 run-instances --network-performance-options BandwidthWeighting=vpc-1 --image-id ami-213123123123" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-instance-network-performance-options" "aws ec2 modify-instance-network-performance-options --instance-id i-1234567890abcdef0 --bandwidth-weighting=vpc-1" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-snapshots" "aws ec2 create-snapshots --instance-specification InstanceId=i-123123123123,ExcludeBootVolume=true,ExcludeDataVolumeIds=vol-123123123123" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm create-lifecycle-policy (1)" "aws dlm create-lifecycle-policy --execution-role-arn foo --description foo --state foo --policy-details {} --default-policy INSTANCE" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm create-lifecycle-policy (2)" "aws dlm create-lifecycle-policy --execution-role-arn foo --description foo --state foo --policy-details \"Schedules={ArchiveRule={RetainRule={}}}\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm update-lifecycle-policy (1)" "aws dlm update-lifecycle-policy --policy-id foo --policy-details \"Schedules={ArchiveRule={RetainRule={}}}\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm create-lifecycle-policy (3)" "aws dlm create-lifecycle-policy --execution-role-arn foo --description foo --state foo --policy-details \"Schedules={FastRestoreRule={}}\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm update-lifecycle-policy (2)" "aws dlm update-lifecycle-policy --policy-id foo --policy-details \"Schedules={FastRestoreRule={}}\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm create-lifecycle-policy (4)" "aws dlm create-lifecycle-policy --execution-role-arn foo --description foo --state foo --policy-details \"Parameters={ExcludeDataVolumeTags=[]}\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm update-lifecycle-policy (3)" "aws dlm update-lifecycle-policy --policy-id foo --policy-details \"Parameters={ExcludeDataVolumeTags=[]}\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm create-lifecycle-policy (5)" "aws dlm create-lifecycle-policy --execution-role-arn foo --description foo --state foo --policy-details \"Exclusions={}\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm update-lifecycle-policy (4)" "aws dlm update-lifecycle-policy --policy-id foo --policy-details \"Exclusions={}\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm create-lifecycle-policy (6)" "aws dlm create-lifecycle-policy --execution-role-arn foo --description foo --state foo --policy-details {} --exclusions {}" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm update-lifecycle-policy (5)" "aws dlm update-lifecycle-policy --policy-id foo --exclusions {}" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm create-lifecycle-policy (7)" "aws dlm create-lifecycle-policy --execution-role-arn foo --description foo --state foo --policy-details \"Schedules={CreateRule={Scripts=[]}}\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "dlm update-lifecycle-policy (6)" "aws dlm update-lifecycle-policy --policy-id foo --policy-details \"Schedules={CreateRule={Scripts=[]}}\"" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-vpc-endpoint-service-configuration" "aws ec2 create-vpc-endpoint-service-configuration --private-dns-name foo" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-vpc-endpoint-service-configuration" "aws ec2 modify-vpc-endpoint-service-configuration --private-dns-name foo --service-id foo" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-dhcp-options" "aws ec2 create-dhcp-options --dhcp-configurations Key=ipv6-address-preferred-lease-time,Values=1000" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 modify-subnet-attribute" "aws ec2 modify-subnet-attribute --subnet-id subnet-1a2b3c4d --enable-dns64" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-subnet" "aws ec2 create-subnet --vpc-id vpc-123123123123 --ipv6-native" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-flow-logs (1)" "aws ec2 create-flow-logs --log-format '\${version} \${account-id} \${ecs-cluster-arn}' --resource-ids vpc-123123123123 --resource-type VPC" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-flow-logs (2)" "aws ec2 create-flow-logs --log-format '\${version} \${account-id} \${ecs-cluster-name}' --resource-ids vpc-123123123123 --resource-type VPC" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-flow-logs (3)" "aws ec2 create-flow-logs --log-format '\${version} \${account-id} \${ecs-cluster-arn} \${ecs-cluster-name}' --resource-ids vpc-123123123123 --resource-type VPC" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-flow-logs (4)" "aws ec2 create-flow-logs --log-format '\${version} \${ecs-cluster-name} \${account-id}' --resource-ids vpc-123123123123 --resource-type VPC" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-flow-logs (5)" "aws ec2 create-flow-logs --log-format '\${version} \${ecs-cluster-arn} \${ecs-cluster-name} \${account-id}' --resource-ids vpc-123123123123 --resource-type VPC" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-flow-logs (6)" "aws ec2 create-flow-logs --log-format '\${ecs-cluster-arn} \${version} \${account-id}' --resource-ids vpc-123123123123 --resource-type VPC" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 create-flow-logs (7)" "aws ec2 create-flow-logs --log-format '\${ecs-cluster-arn}' --resource-ids vpc-123123123123 --resource-type VPC" "Combine rejected this AWS API\|is not supported in this region"
validate_expected_error_match "ec2 describe-route-servers" "aws ec2 describe-route-servers" "Combine rejected this AWS API\|is not supported in this region"
log ""
log "########################"
log "# 87. ELB and ELBv2 lifecycle – rewrites, validation errors and cleanup"
log "########################"

ELB_NAME="Foo${RUN_SUFFIX}"
ELBV2_NAME="Bar${RUN_SUFFIX}"
ELB_ARN="" TG_ARN="" LISTENER_ARN="" LISTENER_2_ARN="" RULE_ARN="" TG_TCP_ARN="" TG_HTTP_ARN="" TG_TCP_IP_ARN=""

validate_rewrite_smart "elb create-load-balancer" "aws elb create-load-balancer --scheme internal --listeners Protocol=HTTP,InstanceProtocol=HTTP,LoadBalancerPort=80,InstancePort=8080 --subnets $SUBNET_1 --load-balancer-name $ELB_NAME"
validate_expected_error_match "elb modify-load-balancer-attributes (desync mitigation)" "aws elb modify-load-balancer-attributes --load-balancer-name $ELB_NAME --load-balancer-attributes \"AdditionalAttributes=[{Key=elb.http.desyncmitigationmode,Value=monitor}]\"" "ValidationError\|InvalidConfigurationRequest\|Combine rejected"
validate_rewrite_smart "elb describe-load-balancers" "aws elb describe-load-balancers --load-balancer-names $ELB_NAME"
validate_success "elb delete-load-balancer" "aws elb delete-load-balancer --load-balancer-name $ELB_NAME"

validate_rewrite_smart "elbv2 create-load-balancer (internal)" "aws elbv2 create-load-balancer --scheme internal --subnets $SUBNET_1 $SUBNET_2 $SUBNET_3 --name $ELBV2_NAME" "" ".LoadBalancers[0].LoadBalancerArn" "ELB_ARN"
validate_rewrite_smart "elbv2 describe-load-balancers (arn)" "aws elbv2 describe-load-balancers --load-balancer-arns \$ELB_ARN"
validate_rewrite_smart "elbv2 describe-load-balancers (name)" "aws elbv2 describe-load-balancers --names $ELBV2_NAME"
validate_rewrite_smart "elbv2 create-target-group" "aws elbv2 create-target-group --name ${ELBV2_NAME}TG --protocol HTTP --port 80 --vpc-id $VPC_ID" "" ".TargetGroups[0].TargetGroupArn" "TG_ARN"
validate_rewrite_smart "elbv2 describe-target-groups (name)" "aws elbv2 describe-target-groups --names ${ELBV2_NAME}TG"
validate_rewrite_smart "elbv2 describe-target-groups (arn)" "aws elbv2 describe-target-groups --target-group-arns \$TG_ARN"
validate_rewrite_smart "elbv2 create-listener" "aws elbv2 create-listener --load-balancer-arn \$ELB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=\$TG_ARN" "" ".Listeners[0].ListenerArn" "LISTENER_ARN"
validate_rewrite_smart "elbv2 describe-target-groups (load balancer)" "aws elbv2 describe-target-groups --load-balancer-arn \$ELB_ARN"
validate_rewrite_smart "elbv2 create-listener (forward config)" "aws elbv2 create-listener --load-balancer-arn \$ELB_ARN --protocol HTTP --port 8080 --default-actions \"Type=forward,ForwardConfig={TargetGroups=[{TargetGroupArn=\$TG_ARN,Weight=100}]}\"" "" ".Listeners[0].ListenerArn" "LISTENER_2_ARN"
validate_rewrite_smart "elbv2 describe-listeners (arn)" "aws elbv2 describe-listeners --listener-arns \$LISTENER_ARN"
validate_rewrite_smart "elbv2 describe-listeners (load balancer)" "aws elbv2 describe-listeners --load-balancer-arn \$ELB_ARN"
validate_rewrite_smart "elbv2 describe-tags" "aws elbv2 describe-tags --resource-arns \$TG_ARN \$ELB_ARN \$LISTENER_ARN"
validate_rewrite_smart "elbv2 create-rule" "aws elbv2 create-rule --listener-arn \$LISTENER_ARN --priority 5 --conditions '[ { \"Field\": \"path-pattern\", \"PathPatternConfig\": { \"Values\": [\"/images/*\"] } } ]' --actions Type=forward,TargetGroupArn=\$TG_ARN" "" ".Rules[0].RuleArn" "RULE_ARN"
validate_success "elbv2 delete-rule" "aws elbv2 delete-rule --rule-arn \$RULE_ARN"
validate_success "elbv2 modify-load-balancer-attributes" "aws elbv2 modify-load-balancer-attributes --load-balancer-arn \$ELB_ARN --attributes Key=deletion_protection.enabled,Value=false"
validate_expected_error_match "elbv2 modify-load-balancer-attributes (desync mitigation)" "aws elbv2 modify-load-balancer-attributes --load-balancer-arn \$ELB_ARN --attributes Key=routing.http.desync_mitigation_mode,Value=monitor" "ValidationError\|Combine rejected"
validate_success "elbv2 delete-listener" "aws elbv2 delete-listener --listener-arn \$LISTENER_ARN"
validate_success "elbv2 delete-listener (forward config)" "aws elbv2 delete-listener --listener-arn \$LISTENER_2_ARN"
validate_success "elbv2 delete-target-group" "aws elbv2 delete-target-group --target-group-arn \$TG_ARN"
validate_success "elbv2 delete-load-balancer" "aws elbv2 delete-load-balancer --load-balancer-arn \$ELB_ARN"

validate_rewrite_smart "elbv2 create-target-group (TCP)" "aws elbv2 create-target-group --name TCP${RUN_SUFFIX} --protocol TCP --port 80 --vpc-id $VPC_ID" "" ".TargetGroups[0].TargetGroupArn" "TG_TCP_ARN"
validate_rewrite_smart "elbv2 create-target-group (HTTP)" "aws elbv2 create-target-group --name HTTP${RUN_SUFFIX} --protocol HTTP --port 80 --vpc-id $VPC_ID" "" ".TargetGroups[0].TargetGroupArn" "TG_HTTP_ARN"
validate_expected_error_match "elbv2 modify-target-group-attributes (TCP stickiness)" "aws elbv2 modify-target-group-attributes --target-group-arn \$TG_TCP_ARN --attributes Key=stickiness.enabled,Value=true" "ValidationError"
validate_expected_error_match "elbv2 modify-target-group-attributes (app cookie)" "aws elbv2 modify-target-group-attributes --target-group-arn \$TG_HTTP_ARN --attributes Key=stickiness.type,Value=app_cookie" "ValidationError"
validate_success "elbv2 modify-target-group-attributes (TCP stickiness off)" "aws elbv2 modify-target-group-attributes --target-group-arn \$TG_TCP_ARN --attributes Key=stickiness.enabled,Value=false"
validate_success "elbv2 modify-target-group-attributes (lb cookie)" "aws elbv2 modify-target-group-attributes --target-group-arn \$TG_HTTP_ARN --attributes Key=stickiness.type,Value=lb_cookie"
validate_success "elbv2 delete-target-group (TCP)" "aws elbv2 delete-target-group --target-group-arn \$TG_TCP_ARN"
validate_success "elbv2 delete-target-group (HTTP)" "aws elbv2 delete-target-group --target-group-arn \$TG_HTTP_ARN"

validate_rewrite_smart "elbv2 create-target-group (TCP, ip targets)" "aws elbv2 create-target-group --name IP${RUN_SUFFIX} --protocol TCP --port 80 --vpc-id $VPC_ID --target-type ip" "" ".TargetGroups[0].TargetGroupArn" "TG_TCP_IP_ARN"
validate_expected_error_match "elbv2 register-targets (disallowed IPs, per AZ)" "aws elbv2 register-targets --target-group-arn \$TG_TCP_IP_ARN --targets Id=100.255.255.255,Port=80,AvailabilityZone=us-iso-east-1a Id=100.255.255.128,Port=80,AvailabilityZone=us-iso-east-1b Id=100.255.255.0,Port=80,AvailabilityZone=us-iso-east-1c" "IP address is not allowed\|ValidationError"
validate_expected_error_match "elbv2 register-targets (disallowed IPs, all AZs)" "aws elbv2 register-targets --target-group-arn \$TG_TCP_IP_ARN --targets Id=100.255.255.255,Port=80,AvailabilityZone=all" "IP address is not allowed\|ValidationError"
validate_success "elbv2 deregister-targets (per AZ)" "aws elbv2 deregister-targets --target-group-arn \$TG_TCP_IP_ARN --targets Id=100.255.255.255,Port=80,AvailabilityZone=us-iso-east-1a Id=100.255.255.128,Port=80,AvailabilityZone=us-iso-east-1b Id=100.255.255.0,Port=80,AvailabilityZone=us-iso-east-1c"
validate_success "elbv2 deregister-targets (all AZs)" "aws elbv2 deregister-targets --target-group-arn \$TG_TCP_IP_ARN --targets Id=100.255.255.255,Port=80,AvailabilityZone=all"
validate_success "elbv2 delete-target-group (ip targets)" "aws elbv2 delete-target-group --target-group-arn \$TG_TCP_IP_ARN"

validate_expected_error_match "elb create-load-balancer (internet-facing, no default VPC)" "aws elb create-load-balancer --scheme internet-facing --listeners Protocol=HTTP,InstanceProtocol=HTTP,LoadBalancerPort=80,InstancePort=8080 --load-balancer-name $ELB_NAME --availability-zones us-iso-east-1a us-iso-east-1b us-iso-east-1c" "efault VPC"

log ""
log "########################"
log "# 88. S3 bucket notifications to SNS – rewrites"
log "########################"

S3_TOPIC_ARN=""
validate_rewrite_smart "sns create-topic (S3 notifications)" "aws sns create-topic --name S3Test${RUN_SUFFIX}" "" ".TopicArn" "S3_TOPIC_ARN"
validate_success "sns set-topic-attributes (allow S3)" "aws sns set-topic-attributes --topic-arn \$S3_TOPIC_ARN --attribute-name Policy --attribute-value '{\"Version\": \"2012-10-17\",\"Statement\": [{\"Effect\": \"Allow\",\"Principal\": { \"Service\": \"s3.amazonaws.com\" },\"Action\": [ \"SNS:Publish\" ],\"Resource\": \"'\$S3_TOPIC_ARN'\",\"Condition\": {\"ArnLike\": {\"aws:SourceArn\": \"arn:aws-iso:s3:*:*:*\"},\"StringEquals\": {\"aws:SourceAccount\": \"663117128738\"} } } ] }'"
require_tf "s3api put-bucket-notification-configuration (SNS)" TF_S3_BUCKET_PERMISSIONS && validate_success "s3api put-bucket-notification-configuration (SNS)" "aws s3api put-bucket-notification-configuration --bucket $S3_TEST_BUCKET --endpoint https://s3.us-iso-east-1.c2s.ic.gov --notification-configuration '{\"TopicConfigurations\": [{\"TopicArn\": \"'\$S3_TOPIC_ARN'\", \"Events\": [\"s3:ObjectCreated:*\"]}]}'"
require_tf "s3api get-bucket-notification-configuration" TF_S3_BUCKET_PERMISSIONS && validate_rewrite_smart "s3api get-bucket-notification-configuration" "aws s3api get-bucket-notification-configuration --bucket $S3_TEST_BUCKET --endpoint https://s3.us-iso-east-1.c2s.ic.gov"
require_tf "s3api put-bucket-notification-configuration (clear)" TF_S3_BUCKET_PERMISSIONS && validate_success "s3api put-bucket-notification-configuration (clear)" "aws s3api put-bucket-notification-configuration --bucket $S3_TEST_BUCKET --notification-configuration '{}'"
validate_success "sns delete-topic (S3 notifications)" "aws sns delete-topic --topic-arn \$S3_TOPIC_ARN"

log ""
log "########################"
log "# 89. EC2 volume types – io2 rejected, gp2 allowed"
log "########################"

VID=""
validate_expected_error_match "ec2 create-volume (io2)" "aws ec2 create-volume --size 1 --volume-type io2 --availability-zone us-iso-east-1a" "volume type\|Combine rejected"
validate_rewrite_smart "ec2 create-volume (gp2)" "aws ec2 create-volume --size 1 --volume-type gp2 --availability-zone us-iso-east-1a" "" ".VolumeId" "VID"
validate_expected_error_match "ec2 modify-volume (io2)" "aws ec2 modify-volume --volume-id \$VID --volume-type io2" "volume type\|Combine rejected"
validate_success "ec2 delete-volume (gp2)" "aws ec2 delete-volume --volume-id \$VID"

log ""
log "########################"
log "# 90. Secrets Manager – rewrites"
log "########################"

SECRET_NAME="CombineTest${RUN_SUFFIX}"
SECRET_ARN=""
if require_tf "secretsmanager create-secret" TF_KMS_KEY_ARN; then
  validate_rewrite_smart "secretsmanager create-secret" "aws secretsmanager create-secret --name $SECRET_NAME --kms-key-id $TF_KMS_KEY_ARN" "" ".ARN" "SECRET_ARN"
  validate_rewrite_smart "secretsmanager describe-secret" "aws secretsmanager describe-secret --secret-id \$SECRET_ARN"
  validate_rewrite_smart "secretsmanager list-secrets (filter by name)" "aws secretsmanager list-secrets --filters Key=name,Values=$SECRET_NAME"
  # NOTE: Deviates from the manual test (plain delete) so each run does not leave a secret pending deletion for 30 days.
  validate_rewrite_smart "secretsmanager delete-secret" "aws secretsmanager delete-secret --secret-id $SECRET_NAME --force-delete-without-recovery"
  validate_success "secretsmanager list-secrets (after delete)" "aws secretsmanager list-secrets --filters Key=name,Values=$SECRET_NAME"
fi

log ""
log "########################"
log "# 91. Route 53 – CIDR collections and endpoint validation"
log "########################"

CIDR_COLLECTION_ID=""
validate_rewrite_smart "route53 create-cidr-collection" "aws route53 create-cidr-collection --name CombineTest${RUN_SUFFIX} --caller-reference CombineTest${RUN_SUFFIX}" "" ".Collection.Id" "CIDR_COLLECTION_ID"
validate_success "route53 list-cidr-collections" "aws route53 list-cidr-collections"
validate_success "route53 delete-cidr-collection" "aws route53 delete-cidr-collection --id \$CIDR_COLLECTION_ID"
validate_expected_error_match "route53 list-hosted-zones-by-vpc (regional endpoint)" "aws route53 list-hosted-zones-by-vpc --vpc-id $VPC_ID --vpc-region us-iso-east-1 --endpoint-url https://route53.us-iso-east-1.c2s.ic.gov" "An error occurred\|Could not connect"

log ""
log "########################"
log "# 92. Route 53 Resolver endpoint – rewrites"
log "########################"

R53R_ENDPOINT_ID="" R53R_ARN=""
if require_tf "route53resolver create-resolver-endpoint" TF_CLI_NETWORK_SECURITY_GROUP_ID; then
  validate_rewrite_smart "route53resolver create-resolver-endpoint" "aws route53resolver create-resolver-endpoint --name combine-test${RUN_SUFFIX} --creator-request-id combine-test${RUN_SUFFIX} --security-group-ids $TF_CLI_NETWORK_SECURITY_GROUP_ID --direction INBOUND --ip-addresses SubnetId=$SUBNET_1 SubnetId=$SUBNET_2" "" ".ResolverEndpoint.Id" "R53R_ENDPOINT_ID"
  R53R_ARN=$(aws route53resolver get-resolver-endpoint --resolver-endpoint-id "$R53R_ENDPOINT_ID" --query 'ResolverEndpoint.Arn' --output text 2>/dev/null || true)
  validate_rewrite_smart "route53resolver list-resolver-endpoints" "aws route53resolver list-resolver-endpoints"
  validate_success "route53resolver list-tags-for-resource" "aws route53resolver list-tags-for-resource --resource-arn \$R53R_ARN"
  validate_rewrite_smart "route53resolver delete-resolver-endpoint" "aws route53resolver delete-resolver-endpoint --resolver-endpoint-id \$R53R_ENDPOINT_ID"
fi

log ""
log "########################"
log "# 93. DynamoDB put-item"
log "########################"

require_tf "dynamodb put-item" TF_DYNAMODB_TABLE_NAME && validate_success "dynamodb put-item" "aws dynamodb put-item --table-name \$TF_DYNAMODB_TABLE_NAME --item '{\"test\": {\"S\":\"foo\" } }'"

log ""
log "########################"
log "# 94. IAM policies, versions and roles – request and response rewrites"
log "########################"

IAM_NAME="CombineTest${RUN_SUFFIX}"
validate_rewrite_smart "iam create-policy" "aws iam create-policy --policy-name $IAM_NAME --policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Action\": \"s3:*\", \"Resource\": \"arn:aws-iso:s3:::combine-app-storage-663117128738\" } ] }'"
validate_success "iam create-policy-version" "aws iam create-policy-version --policy-arn arn:aws-iso:iam::663117128738:policy/$IAM_NAME --policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Action\": \"s3:*\", \"Resource\": [ \"arn:aws-iso:s3:::combine-app-storage-663117128738\", \"arn:aws-iso:s3:::combine-app-storage-663117128738-public1\" ] } ] }'"
validate_rewrite_smart "iam create-role" "aws iam create-role --role-name $IAM_NAME --assume-role-policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"AWS\": \"arn:aws-iso:iam::663117128738:root\" }, \"Action\": \"sts:AssumeRole\" } ] }'"
validate_success "iam delete-policy-version" "aws iam delete-policy-version --policy-arn arn:aws-iso:iam::663117128738:policy/$IAM_NAME --endpoint-url https://iam.us-iso-east-1.c2s.ic.gov --version-id v2"
validate_success "iam delete-policy" "aws iam delete-policy --policy-arn arn:aws-iso:iam::663117128738:policy/$IAM_NAME --endpoint-url https://iam.us-iso-east-1.c2s.ic.gov"
validate_success "iam delete-role" "aws iam delete-role --role-name $IAM_NAME --endpoint-url https://iam.us-iso-east-1.c2s.ic.gov"

validate_rewrite_smart "iam create-role (second)" "aws iam create-role --role-name $IAM_NAME --assume-role-policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"AWS\": \"arn:aws-iso:iam::663117128738:root\" }, \"Action\": \"sts:AssumeRole\" } ] }'"
validate_success "iam update-assume-role-policy (Endpoint Server role)" "aws iam update-assume-role-policy --role-name $IAM_NAME --policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"AWS\": \"arn:aws-iso:iam::663117128738:role/Combine-${SHARD}-Endpoints\" }, \"Action\": \"sts:AssumeRole\" } ] }'"
validate_rewrite_smart "iam list-roles" "aws iam list-roles"
validate_instance_type_absent_grep "iam list-roles (no injected service principal role)" "aws iam list-roles" "CombineInjectedServicePrincipal"
validate_rewrite_smart "iam get-role" "aws iam get-role --role-name $IAM_NAME"
validate_success "iam delete-role (second)" "aws iam delete-role --role-name $IAM_NAME"

require_isob "iam create-role (ISO-B EC2 principal)" && validate_rewrite_smart "iam create-role (ISO-B EC2 principal)" "aws iam create-role --role-name ${IAM_NAME}EC2 --assume-role-policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"ec2.sc2s.sgov.gov\" }, \"Action\": \"sts:AssumeRole\" } ] }'" "us-isob-east-1"
require_isob "iam update-assume-role-policy (ISO-B)" && validate_success "iam update-assume-role-policy (ISO-B)" "aws iam update-assume-role-policy --role-name ${IAM_NAME}EC2 --policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Sid\":\"Testing\", \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"ec2.sc2s.sgov.gov\" }, \"Action\": \"sts:AssumeRole\" } ] }' --region us-isob-east-1"
require_isob "iam update-assume-role-policy (ISO-B, federated not rewritten)" && validate_success "iam update-assume-role-policy (ISO-B, federated not rewritten)" "aws iam update-assume-role-policy --role-name ${IAM_NAME}EC2 --policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Sid\":\"Testing\", \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"ec2.sc2s.sgov.gov\", \"Federated\": \"shouldnotberewritten.s3.us-east-1.amazonaws.com/kubernetes:sub\" }, \"Action\": \"sts:AssumeRole\" } ] }' --region us-isob-east-1"
require_isob "iam get-role (ISO-B)" && validate_rewrite_smart "iam get-role (ISO-B)" "aws iam get-role --role-name ${IAM_NAME}EC2" "us-isob-east-1"
require_isob "iam delete-role (ISO-B)" && validate_success "iam delete-role (ISO-B)" "aws iam delete-role --role-name ${IAM_NAME}EC2 --region us-isob-east-1"

validate_rewrite_smart "iam create-policy (star operator in region)" "aws iam create-policy --policy-name ${IAM_NAME}Star --policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Action\": \"ssm:*\", \"Resource\": \"arn:aws-iso:ssm:*:::parameter/*\" } ] }'"
validate_success "iam delete-policy (star operator)" "aws iam delete-policy --policy-arn arn:aws-iso:iam::663117128738:policy/${IAM_NAME}Star"

log ""
log "########################"
log "# 95. Service principal rewriting – IAM roles and S3 bucket policies"
log "########################"

SP_ROLE="${IAM_NAME}SP"
validate_rewrite_smart "iam create-role (logs regional principal)" "aws iam create-role --role-name $SP_ROLE --assume-role-policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"Service\": [ \"logs.us-iso-east-1.amazonaws.com\" ] }, \"Action\": \"sts:AssumeRole\" } ] }'"
validate_rewrite_smart "iam get-role (logs regional principal)" "aws iam get-role --role-name $SP_ROLE"
validate_success "iam delete-role (logs regional principal)" "aws iam delete-role --role-name $SP_ROLE"
validate_expected_error_match "iam create-role (cloudtrail.c2s.ic.gov principal)" "aws iam create-role --role-name $SP_ROLE --assume-role-policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"Service\": [ \"cloudtrail.c2s.ic.gov\" ] }, \"Action\": \"sts:AssumeRole\" } ] }'" "An error occurred"
validate_expected_error_match "iam create-role (commercial EMR principal)" "aws iam create-role --role-name $SP_ROLE --assume-role-policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"Service\": [ \"elasticmapreduce.amazonaws.com\" ] }, \"Action\": \"sts:AssumeRole\" } ] }'" "An error occurred"
require_isob "iam create-role (ISO-B EMR principal)" && validate_expected_error_match "iam create-role (ISO-B EMR principal)" "aws iam create-role --role-name $SP_ROLE --assume-role-policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"Service\": [ \"ec2.sc2s.sgov.gov\", \"elasticmapreduce.sc2s.sgov.gov\" ] }, \"Action\": \"sts:AssumeRole\" } ] }' --region us-isob-east-1" "An error occurred"

if require_tf "s3api put-bucket-policy (service principals)" TF_S3_BUCKET_PERMISSIONS; then
  for principal in ec2.c2s.ic.gov elasticmapreduce.c2s.ic.gov logs.us-iso-east-1.amazonaws.com; do
    validate_success "s3api put-bucket-policy ($principal)" "aws s3api put-bucket-policy --bucket $S3_TEST_BUCKET --policy '{ \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"Service\": [\"$principal\"] }, \"Action\": [ \"s3:*\" ], \"Resource\": [ \"arn:aws-iso:s3:::$S3_TEST_BUCKET\", \"arn:aws-iso:s3:::$S3_TEST_BUCKET/*\" ] } ] }'"
    validate_rewrite_smart "s3api get-bucket-policy ($principal)" "aws s3api get-bucket-policy --bucket $S3_TEST_BUCKET"
    validate_success "s3api delete-bucket-policy ($principal)" "aws s3api delete-bucket-policy --bucket $S3_TEST_BUCKET"
  done
  for principal in cloudtrail.c2s.ic.gov elasticmapreduce.amazonaws.com; do
    validate_expected_error_match "s3api put-bucket-policy ($principal, should fail)" "aws s3api put-bucket-policy --bucket $S3_TEST_BUCKET --policy '{ \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"Service\": [\"$principal\"] }, \"Action\": [ \"s3:*\" ], \"Resource\": [ \"arn:aws-iso:s3:::$S3_TEST_BUCKET\", \"arn:aws-iso:s3:::$S3_TEST_BUCKET/*\" ] } ] }'" "An error occurred"
  done
  validate_success "s3api put-bucket-policy (ELB log delivery)" "aws s3api put-bucket-policy --bucket $S3_TEST_BUCKET --policy '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"AWS\": \"arn:aws-iso:iam::770363063475:root\" }, \"Action\": \"s3:PutObject\", \"Resource\": \"arn:aws-iso:s3:::$S3_TEST_BUCKET/AWSLogs/663117128738/*\" }, { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"delivery.logs.amazonaws.com\" }, \"Action\": \"s3:PutObject\", \"Resource\": \"arn:aws-iso:s3:::$S3_TEST_BUCKET/AWSLogs/663117128738/*\", \"Condition\": { \"StringEquals\": { \"s3:x-amz-acl\": \"bucket-owner-full-control\" } } }, { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"delivery.logs.amazonaws.com\" }, \"Action\": \"s3:GetBucketAcl\", \"Resource\": \"arn:aws-iso:s3:::$S3_TEST_BUCKET\" } ] }'"
  validate_success "s3api delete-bucket-policy (ELB log delivery)" "aws s3api delete-bucket-policy --bucket $S3_TEST_BUCKET"
fi

log ""
log "########################"
log "# 96. RDS engines and versions"
log "########################"

validate_success "rds describe-db-engine-versions (postgres versions)" "aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[*].EngineVersion'" "__nonempty__"
validate_success "rds describe-db-engine-versions (postgres upgrade targets)" "aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[*].ValidUpgradeTarget'" "__nonempty__"
validate_success "rds describe-db-engine-versions (postgres)" "aws rds describe-db-engine-versions --engine postgres" "__nonempty__"
validate_expected_error_match "rds describe-db-engine-versions (sqlserver-ex)" "aws rds describe-db-engine-versions --engine sqlserver-ex" "Combine rejected\|nrecognized"
validate_expected_error_match "rds describe-db-engine-versions (sqlserver-web)" "aws rds describe-db-engine-versions --engine sqlserver-web" "Combine rejected\|nrecognized"
validate_expected_error_match "rds create-db-instance (sqlserver-ex)" "aws rds create-db-instance --db-instance-identifier Test --db-instance-class db.m5.large --engine sqlserver-ex --engine-version 14.5 --master-username Foo --master-user-password 12345678 --db-subnet-group combineendpointtestsubnetgroup --allocated-storage 20" "Combine rejected\|nrecognized"
validate_expected_error_match "rds create-db-instance (sqlserver-web)" "aws rds create-db-instance --db-instance-identifier Test --db-instance-class db.m5.large --engine sqlserver-web --engine-version 14.5 --master-username Foo --master-user-password 12345678 --db-subnet-group combineendpointtestsubnetgroup --allocated-storage 20" "Combine rejected\|nrecognized"
validate_expected_error_match "rds describe-db-instances (filter includes sqlserver-web)" "aws rds describe-db-instances --filters Name=engine,Values=postgres,mysql,sqlserver-web" "Combine rejected\|nrecognized"
validate_rewrite_smart "rds describe-source-regions (all)" "aws rds describe-source-regions"
require_tf "rds create-db-instance (aurora-mysql db.m5.large unsupported)" TF_RDS_SUBNET_GROUP_NAME && validate_expected_error_match "rds create-db-instance (aurora-mysql db.m5.large unsupported)" "aws rds create-db-instance --master-username combineadmin --master-user-password Combine1275317 --db-subnet-group-name \$TF_RDS_SUBNET_GROUP_NAME --db-instance-identifier CombineEndpointTestInstance --db-instance-class db.m5.large --allocated-storage 8 --engine aurora-mysql --availability-zone us-iso-east-1a" "Invalid DB Instance class"
validate_expected_error_match "rds create-db-cluster (manage master user password)" "aws rds create-db-cluster --master-username foo --manage-master-user-password --master-user-secret-kms-key-id arn:aws-iso:kms:us-iso-east-1:663117128738:key/778b96a8-e41c-4a4d-a09e-368526bbf0d4 --database-name Test --db-cluster-identifier Test --db-cluster-instance-class db.m6gd.xlarge --engine aurora-mysql --engine-version 5.7.mysql_aurora.2.11.2 --db-subnet-group-name default --vpc-security-group-ids sg-123456789abcdefgh" "Combine rejected this AWS API"

log ""
log "########################"
log "# 97. ECS – rewrites"
log "########################"

ECS_TASK_ARN=""
validate_success "ecs list-clusters" "aws ecs list-clusters"
validate_rewrite_smart "ecs discover-poll-endpoint" "aws ecs discover-poll-endpoint --cluster arn:aws-iso:ecs:us-iso-east-1:663117128738:cluster/Test"
cat > ecs_task.json <<EOF
{
  "containerDefinitions": [ { "name": "sleep", "image": "busybox", "cpu": 10, "command": [ "sleep", "360" ], "memory": 10, "essential": true } ],
  "placementConstraints": [
    { "type": "memberOf", "expression": "attribute:ecs.availability-zone in [us-iso-east-1a]" },
    { "type": "memberOf", "expression": "attribute:ecs.vpc-id == $VPC_ID" }
  ],
  "family": "sleep360${RUN_SUFFIX}"
}
EOF
validate_rewrite_smart "ecs register-task-definition" "aws ecs register-task-definition --cli-input-json file://ecs_task.json" "" ".taskDefinition.taskDefinitionArn" "ECS_TASK_ARN"
validate_rewrite_smart "ecs deregister-task-definition" "aws ecs deregister-task-definition --task-definition \$ECS_TASK_ARN"

log ""
log "########################"
log "# 98. Glue connection – rewrites"
log "########################"

GLUE_CONNECTION="combine-test${RUN_SUFFIX,,}"
GLUE_CREATED=""
validate_success "glue create-connection" "aws glue create-connection --connection-input '{ \"Name\":\"$GLUE_CONNECTION\", \"Description\":\"Combine\", \"ConnectionType\":\"KAFKA\", \"ConnectionProperties\": { \"KAFKA_BOOTSTRAP_SERVERS\":\"combine\", \"KAFKA_SSL_ENABLED\":\"true\", \"KAFKA_CUSTOM_CERT\": \"s3://bucket/prefix/cert-file.pem\", \"KAFKA_SASL_SCRAM_SECRETS_ARN\": \"arn:aws-iso:secretsmanager:us-iso-east-1:663117128738:secret:aws-example_secret-IWXmrw\", \"ROLE_ARN\": \"arn:aws-iso:iam::663117128738:role/Combine-${SHARD}-TS-WLDEVELOPER\", \"REGION\": \"us-iso-east-1\" }, \"AuthenticationConfiguration\": { \"SecretArn\": \"arn:aws-iso:secretsmanager:us-iso-east-1:663117128738:secret:aws-example_secret-IWXmrw\" }, \"PhysicalConnectionRequirements\":{ \"SubnetId\":\"subnet-1234\", \"SecurityGroupIdList\":[\"sg-1234\"], \"AvailabilityZone\":\"us-iso-east-1a\" } }'"
aws glue get-connection --name "$GLUE_CONNECTION" >/dev/null 2>&1 && GLUE_CREATED=yes
require_value "glue get-connection" GLUE_CREATED && validate_rewrite_smart "glue get-connection" "aws glue get-connection --name $GLUE_CONNECTION"
require_value "glue delete-connection" GLUE_CREATED && validate_success "glue delete-connection" "aws glue delete-connection --connection-name $GLUE_CONNECTION"

log ""
log "########################"
log "# 99. Recycle Bin rule – rewrites and tagging"
log "########################"

RBIN_ID=""
validate_rewrite_smart "rbin create-rule" "aws rbin create-rule --retention-period RetentionPeriodValue=7,RetentionPeriodUnit=DAYS --resource-type EBS_SNAPSHOT --description CombineTest${RUN_SUFFIX}" "" ".Identifier" "RBIN_ID"
validate_rewrite_smart "rbin list-rules" "aws rbin list-rules --resource-type EBS_SNAPSHOT"
validate_rewrite_smart "rbin get-rule" "aws rbin get-rule --identifier \$RBIN_ID"
validate_success "rbin list-tags-for-resource" "aws rbin list-tags-for-resource --resource-arn arn:aws-iso:rbin:us-iso-east-1:663117128738:rule/\$RBIN_ID"
validate_success "rbin tag-resource" "aws rbin tag-resource --resource-arn arn:aws-iso:rbin:us-iso-east-1:663117128738:rule/\$RBIN_ID --tags Key=Test,Value=Test"
validate_success "rbin list-tags-for-resource (tagged)" "aws rbin list-tags-for-resource --resource-arn arn:aws-iso:rbin:us-iso-east-1:663117128738:rule/\$RBIN_ID" "Test"
validate_success "rbin untag-resource" "aws rbin untag-resource --resource-arn arn:aws-iso:rbin:us-iso-east-1:663117128738:rule/\$RBIN_ID --tag-keys Test"
validate_success "rbin delete-rule" "aws rbin delete-rule --identifier \$RBIN_ID"

log ""
log "########################"
log "# 100. GuardDuty detector – rewrites and tagging"
log "########################"

# NOTE: An account/region allows one detector. Reuse an existing one and never delete it.
DETECTOR_ID=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text 2>/dev/null || true)
DETECTOR_CREATED=false
if [[ -z "$DETECTOR_ID" || "$DETECTOR_ID" == "None" ]]; then
  validate_success "guardduty create-detector" "aws guardduty create-detector --enable" "__nonempty__"
  DETECTOR_ID=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text 2>/dev/null || true)
  DETECTOR_CREATED=true
else
  log "ℹ️  Reusing existing GuardDuty detector $DETECTOR_ID (it will not be deleted)"
fi
validate_rewrite_smart "guardduty get-detector" "aws guardduty get-detector --detector-id $DETECTOR_ID"
validate_success "guardduty tag-resource" "aws guardduty tag-resource --resource-arn arn:aws-iso:guardduty:us-iso-east-1:663117128738:detector/$DETECTOR_ID --tags CombineTest=Test"
validate_success "guardduty list-tags-for-resource (tagged)" "aws guardduty list-tags-for-resource --resource-arn arn:aws-iso:guardduty:us-iso-east-1:663117128738:detector/$DETECTOR_ID" "CombineTest"
validate_success "guardduty untag-resource" "aws guardduty untag-resource --resource-arn arn:aws-iso:guardduty:us-iso-east-1:663117128738:detector/$DETECTOR_ID --tag-keys CombineTest"
[[ "$DETECTOR_CREATED" == true ]] && validate_success "guardduty delete-detector" "aws guardduty delete-detector --detector-id $DETECTOR_ID"

log ""
log "########################"
log "# 101. Resource Groups Tagging API – rewrites, using this test server's instance"
log "########################"

IMDS_TOKEN=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)
RUNNER_INSTANCE_ID=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)
validate_rewrite_smart "resourcegroupstaggingapi get-resources" "aws resourcegroupstaggingapi get-resources --max-items 20"
if [[ "$RUNNER_INSTANCE_ID" == i-* ]]; then
  TEST_EC2_INSTANCE_ARN="arn:aws-iso:ec2:us-iso-east-1:663117128738:instance/$RUNNER_INSTANCE_ID"
  validate_rewrite_smart "resourcegroupstaggingapi get-resources (instance)" "aws resourcegroupstaggingapi get-resources --resource-arn-list $TEST_EC2_INSTANCE_ARN"
  validate_success "resourcegroupstaggingapi tag-resources" "aws resourcegroupstaggingapi tag-resources --resource-arn-list $TEST_EC2_INSTANCE_ARN --tags CombineTest=Test"
  validate_success "resourcegroupstaggingapi get-resources (tagged)" "aws resourcegroupstaggingapi get-resources --resource-arn-list $TEST_EC2_INSTANCE_ARN" "CombineTest"
  validate_success "resourcegroupstaggingapi untag-resources" "aws resourcegroupstaggingapi untag-resources --resource-arn-list $TEST_EC2_INSTANCE_ARN --tag-keys CombineTest"
else
  echo "🔍 resourcegroupstaggingapi instance tagging: ⏭️ Skipped (not running on an EC2 instance)"
  record_skip
fi

log ""
log "########################"
log "# 102. Resource Groups – CloudFormation stack query rewrites"
log "########################"

RG_NAME="CombineTest${RUN_SUFFIX}"
RG_STACK_ID=$(aws cloudformation describe-stacks --stack-name "Combine-${SHARD}-VPC" --query 'Stacks[0].StackId' --output text 2>/dev/null || true)
if [[ "$RG_STACK_ID" == arn:* ]]; then
  validate_rewrite_smart "resource-groups create-group" "aws resource-groups create-group --name $RG_NAME --resource-query '{\"Type\": \"CLOUDFORMATION_STACK_1_0\", \"Query\": \"{\\\"ResourceTypeFilters\\\":[\\\"AWS::AllSupported\\\"],\\\"StackIdentifier\\\":\\\"$RG_STACK_ID\\\"}\"}'"
  validate_rewrite_smart "resource-groups get-group" "aws resource-groups get-group --group arn:aws-iso:resource-groups:us-iso-east-1:663117128738:group/$RG_NAME"
  validate_rewrite_smart "resource-groups list-groups" "aws resource-groups list-groups"
  validate_rewrite_smart "resource-groups get-tags" "aws resource-groups get-tags --arn arn:aws-iso:resource-groups:us-iso-east-1:663117128738:group/$RG_NAME"
  validate_rewrite_smart "resource-groups delete-group" "aws resource-groups delete-group --group arn:aws-iso:resource-groups:us-iso-east-1:663117128738:group/$RG_NAME"
else
  echo "🔍 resource-groups lifecycle: ⏭️ Skipped (stack Combine-${SHARD}-VPC not found)"
  record_skip
fi

log ""
log "########################"
log "# 103. Image Builder infrastructure configuration – rewrites"
log "########################"

IB_ARN=""
validate_rewrite_smart "imagebuilder create-infrastructure-configuration" "aws imagebuilder create-infrastructure-configuration --name Foo${RUN_SUFFIX} --instance-profile-name Combine-${SHARD}-TS-WLDEVELOPER-EC2" "" ".infrastructureConfigurationArn" "IB_ARN"
validate_rewrite_smart "imagebuilder delete-infrastructure-configuration" "aws imagebuilder delete-infrastructure-configuration --infrastructure-configuration-arn \$IB_ARN"

log ""
log "########################"
log "# 104. MSK (Kafka) serverless cluster and configuration – rewrites and tagging"
log "########################"

KAFKA_CLUSTER_ARN="" KAFKA_CONFIGURATION_ARN=""
if require_long "kafka cluster lifecycle" && require_tf "kafka create-cluster-v2" TF_CLI_NETWORK_SECURITY_GROUP_ID && [[ -n "$SUBNET_3" ]]; then
  validate_rewrite_smart "kafka create-cluster-v2 (serverless)" "aws kafka create-cluster-v2 --cluster-name CombineTest${RUN_SUFFIX} --serverless 'VpcConfigs=[{SubnetIds=[$SUBNET_1,$SUBNET_2,$SUBNET_3],SecurityGroupIds=[$TF_CLI_NETWORK_SECURITY_GROUP_ID]}],ClientAuthentication={Sasl={Iam={Enabled=true}}}'" "" ".ClusterArn" "KAFKA_CLUSTER_ARN"
  require_value "kafka list-tags-for-resource" KAFKA_CLUSTER_ARN && validate_success "kafka list-tags-for-resource" "aws kafka list-tags-for-resource --resource-arn \$KAFKA_CLUSTER_ARN"
  require_value "kafka tag-resource" KAFKA_CLUSTER_ARN && validate_success "kafka tag-resource" "aws kafka tag-resource --resource-arn \$KAFKA_CLUSTER_ARN --tags CombineTest=Test"
  require_value "kafka list-tags-for-resource (tagged)" KAFKA_CLUSTER_ARN && validate_success "kafka list-tags-for-resource (tagged)" "aws kafka list-tags-for-resource --resource-arn \$KAFKA_CLUSTER_ARN" "CombineTest"
  require_value "kafka untag-resource" KAFKA_CLUSTER_ARN && validate_success "kafka untag-resource" "aws kafka untag-resource --resource-arn \$KAFKA_CLUSTER_ARN --tag-keys CombineTest"
  validate_rewrite_smart "kafka list-clusters-v2" "aws kafka list-clusters-v2"
  require_value "kafka describe-cluster-v2" KAFKA_CLUSTER_ARN && validate_rewrite_smart "kafka describe-cluster-v2" "aws kafka describe-cluster-v2 --cluster-arn \$KAFKA_CLUSTER_ARN"
  if [[ -n "$KAFKA_CLUSTER_ARN" ]]; then
    log "⏳ Waiting for MSK cluster to become ACTIVE so it can be deleted..."
    wait_until 1800 "[[ \$(aws kafka describe-cluster-v2 --cluster-arn \"\$KAFKA_CLUSTER_ARN\" --query 'ClusterInfo.State' --output text) == ACTIVE ]]" || log "⚠️  MSK cluster did not become ACTIVE in time"
  fi
  require_value "kafka delete-cluster" KAFKA_CLUSTER_ARN && validate_rewrite_smart "kafka delete-cluster" "aws kafka delete-cluster --cluster-arn \$KAFKA_CLUSTER_ARN"
fi
echo "auto.create.topics.enable=false" > kafka_server.properties
validate_rewrite_smart "kafka create-configuration" "aws kafka create-configuration --name CombineTest${RUN_SUFFIX} --description Foo --kafka-versions 2.2.1 --server-properties fileb://kafka_server.properties" "" ".Arn" "KAFKA_CONFIGURATION_ARN"
require_value "kafka describe-configuration" KAFKA_CONFIGURATION_ARN && validate_rewrite_smart "kafka describe-configuration" "aws kafka describe-configuration --arn \$KAFKA_CONFIGURATION_ARN"
require_value "kafka delete-configuration" KAFKA_CONFIGURATION_ARN && validate_rewrite_smart "kafka delete-configuration" "aws kafka delete-configuration --arn \$KAFKA_CONFIGURATION_ARN"

log ""
log "########################"
log "# CLI Commands Called"
log "# (${#COMMANDS_RUN[@]} total)"
log "########################"
for cmd in "${COMMANDS_RUN[@]}"; do
  log "  $cmd"
done

log ""
log "###############################################"
log "# Test Summary"
log "###############################################"
TOTAL=$((PASS + FAIL + SKIP))
log ""
log "  Total:     $TOTAL"
log "  ✅ Passed:  $PASS"
log "  ❌ Failed:  $FAIL"
log "  ⏭️  Skipped: $SKIP"
if [[ -n "${EKS_REGION:-}" ]]; then
  log ""
  log "  EKS (section 82): PASS=$EKS_PASS FAIL=$EKS_FAIL SKIP=$EKS_SKIP"
fi
log ""
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  log "  🎉 All tests passed!"
else
  log "  Failed tests (review output above or check $LOGFILE for details):"
  log ""
  for f in "${FAILURES[@]}"; do
    log "    ❌  $f"
  done
  log ""
  log "  Common things to check:"
  log "    • Credentials/endpoint — ensure AWS_* env vars and endpoint config are correct"
  log "    • Rewriter — if 'no ISO ARNs/regions detected', the response rewriter may not be running"
  log "    • Encoding — a 403 on an expected-error test usually means a URI encoding bug in the proxy"
  log "    • Instance/node types — 'not filtered' failures indicate a missing entry in the type filter list"
  log "    • S3 access — upload/download failures point to bucket policy or credential scope issues"
fi

# NOTE: Skipped tests do not fail the run; any failed test does.
[[ "$FAIL" -eq 0 ]] || exit 1
