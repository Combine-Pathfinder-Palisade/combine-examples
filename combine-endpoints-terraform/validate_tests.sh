#!/bin/bash
set -uo pipefail

LOGFILE="validate_results.log"
touch $LOGFILE

function log() {
  echo -e "$1" | tee -a $LOGFILE
}

#############################
# GET VPC ID need a better way to do this..
# Maybe we can have some sort of external file with the variables? 
# Something we only edit once and then I can reference in some way that doesn't require multiple changes
#############################

export VPC_ID=vpc-01e95d9106c2c1ef6
UNSUPPORTED_INSTANCE_TYPE="db.r7i.large"
UNSUPPORTED_EMR_TYPE_1="m7i.xlarge"
UNSUPPORTED_EMR_TYPE_2="m7i.2xlarge"

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
  "KmsMasterKeyId": "arn:aws-iso:kms:us-iso-east-1:663117128738:key/1c420142-fcc7-492a-a5b7-892bb3764ab7"
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
  local exception_pattern="${6:-}"  # Optional: values that should NOT match rewrite regex

  local pattern="arn:aws-iso(-b)?:|us-iso(-b)?|usie\\d?|usiw\\d?|usib\\d?|c2s.ic.gov|sc2s.sgov.gov|gov\.ic\.c2s\.us-iso-east-1|gov\.sgov\.sc2s\.us-isob-east-1|com\.amazonaws\.us-iso(-b)?-east-1\.s3"

  printf "🔍 %s%s: " "$label" "${region:+ ($region)}"

  local full_cmd="$cmd"
  [[ -n "$region" ]] && full_cmd="$cmd --region $region"

  local output
  output=$(eval "$full_cmd" 2>/dev/null)

  if [[ -z "$output" || "$output" == "null" ]]; then
    echo "❌ Failed (empty or invalid response)"
    return 1
  fi

  local matches
  matches=$(echo "$output" | jq -r '.. | scalars | select(type == "string")' | grep -E "$pattern" || true)

  if [[ -n "$matches" ]]; then
    if [[ -n "$exception_pattern" ]]; then
      # Case for validating matches EXCEPT X.. I thought about making this its own function but I hate having special functions for just one case.... might revist LRM
      local bad_matches
      bad_matches=$(echo "$matches" | grep -E "$exception_pattern" || true)
      if [[ -n "$bad_matches" ]]; then
        echo "❌ Failed (unexpected rewrite of exception strings)"
        echo "$bad_matches" | head -n 10
        return 1
      fi
    fi

    echo "✅ Passed"

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

  local output
  output=$(eval "$command" 2>&1)

  if echo "$output" | grep -q "$expected_message"; then
    echo "✅ Passed ($expected_message)"
  else
    if echo "$output" | grep -q "403"; then
      echo "❌ Failed (403 - possible encoding bug)"
    else
      echo "❌ Failed${fallback_message:+ ($fallback_message)}"
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
  output=$(eval "$command" 2>/dev/null)

  if echo "$output" | grep -q "$forbidden"; then
    echo "❌ Failed (found forbidden instance type: $forbidden)"
    echo "$output" | grep "$forbidden"
  else
    echo "✅ Passed (no $forbidden found)"
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

  local output
  if output=$(eval "$command" 2>&1); then
    if [[ "$expected" == "__nonempty__" ]]; then
      if [[ -n "$output" && "$output" != "null" ]]; then
        echo "✅ Passed"
      else
        echo "❌ Failed (empty or null output)"
      fi
    elif [[ -n "$expected" ]]; then
      if [[ "$output" == *"$expected"* ]]; then
        echo "✅ Passed"
      else
        echo "❌ Failed (expected string not found)"
        echo "   🔸 Expected: $expected"
        echo "   🔸 Output: $output" | head -n 10
      fi
    else
      echo "✅ Passed"
    fi
  else
    echo "❌ Failed"
    echo "$output" | head -n 10
  fi
}

#validate_success() {
#  local label="$1"
#  local command="$2"
#
#  printf "🔍 %s: " "$label"
#
#  if output=$(eval "$command" 2>&1); then
#    echo "✅ Passed"
#  else
#    echo "❌ Failed"
#    echo "$output" | head -n 10
#  fi
#}

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
  local bucket="combine-endpoint-test"
  local s3_uri="s3://$bucket/$s3_key"
  local back_file="${source}_back"

  printf "🔍 %s: " "$label"

  if [[ "$mode" == "basic" ]]; then
    if output=$(eval "$source" 2>/dev/null) && [[ "$output" != "null" && -n "$output" ]]; then
      echo "✅ Passed"
    else
      echo "❌ Failed (null or error)"
    fi

  elif [[ "$mode" == "checksum" || "$mode" == "presign" ]]; then
    # Auto-generate test file if it doesn't exist
    if [[ ! -f "$source" ]]; then
      case "$source" in
        smallfile.txt) head -c 500 < /dev/urandom | base64 > "$source" ;;
        file.txt) head -c 50000 < /dev/urandom | base64 > "$source" ;;
        bigfile.txt) head -c 5000000 < /dev/urandom | base64 > "$source" ;;
        megafile.txt) head -c 500000000 < /dev/urandom | base64 > "$source" ;;
        *) echo "❌ Unknown file: $source" && return ;;
      esac
    fi

    # Upload to S3
    if ! aws s3 cp "$source" "$s3_uri" > /dev/null 2>&1; then
      echo "❌ Upload failed"
      return
    fi

    # Download from S3 using wget and presigned URL (for presign mode)
    if [[ "$mode" == "presign" ]]; then
      local url
      url=$(aws s3 presign "$s3_uri")
      if ! wget "$url" -O "$back_file" --no-check-certificate > /dev/null 2>&1; then
        echo "❌ Download (presign) failed"
        return
      fi
    else
      if ! aws s3 cp "$s3_uri" "$back_file" > /dev/null 2>&1; then
        echo "❌ Download failed"
        return
      fi
    fi

    # Compare checksums
    local orig_sum back_sum
    orig_sum=$(md5sum "$source" | awk '{print $1}')
    back_sum=$(md5sum "$back_file" | awk '{print $1}')

    if [[ "$orig_sum" == "$back_sum" ]]; then
      echo "✅ Passed"
    else
      echo "❌ Checksum mismatch"
      echo "   🔸 Original:   $orig_sum"
      echo "   🔸 Downloaded: $back_sum"
    fi

    rm -f "$back_file"

  else
    echo "❌ Unknown mode: $mode"
  fi
}

log ""
log "########################"
log "# 1. Calls should pass, will check rewritten values"
log "########################"

validate_rewrite_smart "ec2 describe-regions" "aws ec2 describe-regions" ""
validate_rewrite_smart "ec2 describe-regions" "aws ec2 describe-regions" "us-iso-west-1"
validate_rewrite_smart "ec2 describe-regions" "aws ec2 describe-regions" "us-isob-east-1"

validate_rewrite_smart "ec2 describe-availability-zones" "aws ec2 describe-availability-zones" ""
validate_rewrite_smart "ec2 describe-availability-zones" "aws ec2 describe-availability-zones" "us-iso-west-1"
validate_rewrite_smart "ec2 describe-availability-zones" "aws ec2 describe-availability-zones" "us-isob-east-1"

validate_rewrite_smart "ec2 describe-subnets" "aws ec2 describe-subnets" ""
validate_rewrite_smart "ec2 describe-subnets" "aws ec2 describe-subnets" "us-iso-west-1"
validate_rewrite_smart "ec2 describe-subnets" "aws ec2 describe-subnets" "us-isob-east-1"

validate_rewrite_smart "trustedadvisor list-checks" "aws trustedadvisor list-checks" ""
validate_rewrite_smart "trustedadvisor list-checks" "aws trustedadvisor list-checks" "us-isob-east-1"

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
validate_expected_error_match "license-manager get-grant" "aws license-manager get-grant --grant-arn foo --region us-isob-east-1" "Combine rejected this AWS API"
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
validate_expected_error_match "workspaces create-updated-workspace-image" "aws workspaces create-updated-workspace-image --name foo --description foo --source-image-id foo --region us-isob-east-1" "Combine rejected this AWS API"
 
log ""
log "########################"
log "# 4. Should return 501 Not Implemented (Unsupported services - implicitly denied)"
log "# These services are unsupported and should trigger Combine-style rejection"
log "########################"

validate_expected_error_match "polly list-lexicons" "aws polly list-lexicons" "Combine rejected this AWS API"
validate_expected_error_match "macie2 list-members" "aws macie2 list-members" "Combine rejected this AWS API"

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
validate_expected_error_match "describe-vpc-classic-link (ISOB)" "aws ec2 describe-vpc-classic-link --region us-isob-east-1" "UnsupportedOperation"
validate_expected_error_match "describe-vpc-classic-link-dns-support" "aws ec2 describe-vpc-classic-link-dns-support" "UnsupportedOperation"
validate_expected_error_match "describe-vpc-classic-link-dns-support (ISOB)" "aws ec2 describe-vpc-classic-link-dns-support --region us-isob-east-1" "UnsupportedOperation"

log ""
log "########################"
log "# 7. S3 Basic Validation"
log "########################"

validate_s3 "S3 list-buckets" "aws s3api list-buckets" "" "basic"
validate_s3 "S3 list-objects" "aws s3api list-objects --bucket combine-endpoint-test" "" "basic"

log ""
log "########################"
log "# 8. S3 Upload + Checksum"
log "########################"

validate_s3 "S3 smallfile.txt" "smallfile.txt" "foo/smallfile.txt" "checksum"
validate_s3 "S3 file.txt" "file.txt" "foo/file.txt" "checksum"
validate_s3 "S3 file++.txt" "file.txt" "foo/bar/baz/file++.txt" "checksum"
validate_s3 "S3 bigfile.txt" "bigfile.txt" "foo/bigfile.txt" "checksum"
validate_s3 "S3 megafile.txt" "megafile.txt" "foo/megafile.txt" "checksum"

log ""
log "########################"
log "# 9. Validate S3 rewrite"
log "########################"

validate_rewrite_smart "s3api put-object (plain)" "aws s3api put-object --bucket combine-endpoint-test --body ./test_cli_upload.txt --key test_cli_upload.txt" ""
validate_rewrite_smart "s3api put-object (KMS)" "aws s3api put-object --bucket combine-endpoint-test --body ./test_cli_upload.txt --key test_cli_upload_kms.txt --ssekms-key-id arn:aws-iso:kms:us-iso-east-1:663117128738:key/98379135-0b5a-484d-a493-05f0f8ebd817 --server-side-encryption aws:kms" ""
validate_rewrite_smart "s3api get-bucket-encryption" "aws s3api get-bucket-encryption --bucket combine-endpoint-test" ""
validate_rewrite_smart "s3api get-bucket-inventory-configuration" "aws s3api get-bucket-inventory-configuration --bucket combine-endpoint-test --id Test" ""
validate_rewrite_smart "s3api list-bucket-inventory-configurations" "aws s3api list-bucket-inventory-configurations --bucket combine-endpoint-test" ""
validate_rewrite_smart "s3api head-bucket" "aws s3api head-bucket --bucket combine-endpoint-test" ""

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
CREATE_CMD="aws s3api create-multipart-upload --bucket combine-endpoint-test --key foobarbaz"
OUTPUT_CREATE=$(eval "$CREATE_CMD" 2>/dev/null)

echo -n "🔍 s3api create-multipart-upload: "
if echo "$OUTPUT_CREATE" | jq -r '.. | scalars | select(type == "string")' | grep -Eq 'arn:aws-iso(-b)?:|us-iso(-b)?|c2s\.ic\.gov|sc2s\.sgov\.gov'; then
  echo "✅ Passed"
else
  echo "❌ Failed (no rewritten strings found)"
  echo "$OUTPUT_CREATE" | jq . | head -n 20
fi

# Extract UploadId
UPLOAD_ID=$(echo "$OUTPUT_CREATE" | jq -r '.UploadId')

# Continue using existing validate_rewrite_smart
validate_rewrite_smart "s3api list-multipart-uploads" "aws s3api list-multipart-uploads --bucket combine-endpoint-test" ""
validate_rewrite_smart "s3api list-parts" "aws s3api list-parts --bucket combine-endpoint-test --key foobarbaz --upload-id $UPLOAD_ID" ""

# Clean up the multipart upload
aws s3api abort-multipart-upload --bucket combine-endpoint-test --key foobarbaz --upload-id $UPLOAD_ID >/dev/null 2>&1
echo "🧹 Aborted multipart upload (UploadId: $UPLOAD_ID)"

log ""
log "########################"
log "# 14. Validate 404 return, if 403 will throw error."
log "########################"

validate_expected_error_match "s3 cp URI (foo++)" "aws s3 cp s3://combine-endpoint-test/foo/foo++.txt ." "404"
validate_expected_error_match "s3 cp deep URI" "aws s3 cp s3://combine-endpoint-test/foo/foo++//bar/baz///boz.txt ." "404"
validate_expected_error_match "head-object foo/foo.txt" "aws s3api head-object --bucket combine-endpoint-test --key foo/foo.txt" "404"
validate_expected_error_match "head-object foo/foo++.txt" "aws s3api head-object --bucket combine-endpoint-test --key foo/foo++.txt" "404"
validate_expected_error_match "head-object foo//foo++.txt" "aws s3api head-object --bucket combine-endpoint-test --key foo//foo++.txt" "404"

log ""
log "########################"
log "# 15. Validate Testing special characters in URI should pass"
log "########################"

validate_success "s3 cp upload (special chars)" 'aws s3 cp smallfile.txt "s3://combine-endpoint-test/foo/bar++/baz/test and test+.txt"'
validate_success "s3 cp upload (nested //)" 'aws s3 cp smallfile.txt "s3://combine-endpoint-test/foo/bar++/baz//boz//bix//test.txt"'
validate_success "s3 cp upload (deep nested ////)" 'aws s3 cp smallfile.txt "s3://combine-endpoint-test/foo/bar++/baz///boz//bix////test.txt"'

validate_success "s3 cp download (special chars)" 'aws s3 cp "s3://combine-endpoint-test/foo/bar++/baz/test and test+.txt" .'
validate_success "s3 cp download (nested //)" 'aws s3 cp "s3://combine-endpoint-test/foo/bar++/baz//boz//bix//test.txt" .'
validate_success "s3 cp download (deep nested ////)" 'aws s3 cp "s3://combine-endpoint-test/foo/bar++/baz///boz//bix////test.txt" .'

validate_success "s3 cp test2.txt" 'aws s3 cp smallfile.txt "s3://combine-endpoint-test/test2.txt"'
validate_success "s3 cp test3.txt" 'aws s3 cp smallfile.txt "s3://combine-endpoint-test/foo/test3.txt"'
validate_success "s3 cp test+.txt" 'aws s3 cp smallfile.txt "s3://combine-endpoint-test/foo/bar++/baz/test and test+.txt"'
validate_success "s3 cp test.txt (nested)" 'aws s3 cp smallfile.txt "s3://combine-endpoint-test/foo/bar++/baz//boz//bix//test.txt"'
validate_success "s3 cp test.txt (deep nested)" 'aws s3 cp smallfile.txt "s3://combine-endpoint-test/foo/bar++/baz///boz//bix////test.txt"'

validate_rewrite_smart "head-object test2.txt" 'aws s3api head-object --bucket combine-endpoint-test --key "test2.txt"' ""
validate_rewrite_smart "head-object test3.txt" 'aws s3api head-object --bucket combine-endpoint-test --key "foo/test3.txt"' ""
validate_rewrite_smart "head-object test+.txt" 'aws s3api head-object --bucket combine-endpoint-test --key "foo/bar++/baz/test and test+.txt"' ""
validate_rewrite_smart "head-object test.txt (nested)" 'aws s3api head-object --bucket combine-endpoint-test --key "foo/bar++/baz//boz//bix//test.txt"' ""
validate_rewrite_smart "head-object test.txt (deep nested)" 'aws s3api head-object --bucket combine-endpoint-test --key "foo/bar++/baz///boz//bix////test.txt"' ""


log ""
log "########################"
log "# 16. Validate it returns empty, the action is a violation but it should still not return anything"
log "########################"

validate_success "s3api get-bucket-accelerate-configuration" "aws s3api get-bucket-accelerate-configuration --bucket combine-endpoint-test"

log ""
log "########################"
log "# 17. Should fail with Unsupported Argument"
log "########################"

validate_expected_error_match "s3api put-bucket-accelerate-configuration (should fail)" "aws s3api put-bucket-accelerate-configuration --bucket combine-endpoint-test --accelerate-configuration {}" "" "UnsupportedArgument"

log ""
log "########################"
log "# 18. Invalid notification events should fail"
log "########################"

validate_expected_error_match "s3api put-bucket-notification-configuration (invalid events)" "aws s3api put-bucket-notification-configuration --bucket combine-endpoint-test --notification-configuration file://s3_bucket_notification.json" "" "InvalidArgument"

log ""
log "########################"
log "# 19. Valid structure but invalid destination should fail"
log "########################"

validate_expected_error_match "s3api put-bucket-notification-configuration (invalid destination)" "aws s3api put-bucket-notification-configuration --bucket combine-endpoint-test --notification-configuration file://s3_bucket_notification_valid.json" "" "InvalidArgument"

log ""
log "########################"
log "# 20. Should fail and give Invalid ARN, testing endpoint resolution"
log "########################"

validate_expected_error_match "stepfunctions start-sync-execution (should fail with InvalidArn)" "aws stepfunctions start-sync-execution --state-machine-arn Foo" "" "InvalidArn"

log ""
log "########################"
log "# 21. Validate values are rewritten should pass"
log "########################"

validate_rewrite_smart "cloudformation describe-stack-events" "aws cloudformation describe-stack-events --stack-name Combine-Dev" ""
validate_rewrite_smart "cloudformation describe-stacks" "aws cloudformation describe-stacks --stack-name Combine-Dev" ""
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


validate_rewrite_smart "cloudtrail create-trail" "aws cloudtrail create-trail --name CombineTest --s3-bucket-name aws-cloudtrail-logs-663117128738-7700349f --s3-key-prefix EndpointsTest --no-is-multi-region-trail --no-include-global-service-events --cloud-watch-logs-log-group-arn arn:aws-iso:logs:us-iso-east-1:663117128738:log-group:CombineTest:* --cloud-watch-logs-role-arn arn:aws-iso:iam::663117128738:role/service-role/CombineTestCloudTrailRole --kms-key-id arn:aws-iso:kms:us-iso-east-1:663117128738:key/3000dcaa-c17a-4e5d-8e3a-5119afa0cf6f" "" ".TrailARN" "TRAIL_ARN"
validate_rewrite_smart "cloudtrail list-trails" "aws cloudtrail list-trails" ""
validate_rewrite_smart "cloudtrail describe-trails" "aws cloudtrail describe-trails --trail-name-list $TRAIL_ARN" ""
validate_rewrite_smart "cloudtrail get-trail" "aws cloudtrail get-trail --name $TRAIL_ARN" ""
validate_rewrite_smart "cloudtrail get-trail-status" "aws cloudtrail get-trail-status --name $TRAIL_ARN" ""

validate_rewrite_smart "cloudtrail put-event-selectors (valid)" "aws cloudtrail put-event-selectors --trail-name CombineTest --event-selectors file://cloudtrail_event_selector_valid.json" ""
validate_rewrite_smart "cloudtrail get-event-selectors" "aws cloudtrail get-event-selectors --trail-name CombineTest" ""

validate_expected_error_match "cloudtrail put-event-selectors (invalid S3 ARN)" "aws cloudtrail put-event-selectors --trail-name CombineTest --event-selectors file://cloudtrail_event_selector_invalid_s3.json" "Unexpected Value for ARN"
validate_expected_error_match "cloudtrail put-event-selectors (invalid Lambda ARN format)" "aws cloudtrail put-event-selectors --trail-name CombineTest --event-selectors file://cloudtrail_event_selector_invalid_lambda.json" "Unexpected Value for ARN"

aws cloudtrail delete-trail --name "$TRAIL_ARN" >/dev/null 2>&1 && log "🧼 Deleted trail $TRAIL_ARN"
unset TRAIL_ARN

log ""
log "########################"
log "# 24. Validate values are rewritten in response (DynamoDB)"
log "########################"


validate_rewrite_smart "dynamodb describe-table" "aws dynamodb describe-table --table-name tf-combine-endpoints-test-gt" ""
validate_rewrite_smart "dynamodb create-backup" "aws dynamodb create-backup --table-name tf-combine-endpoints-test-gt --backup-name Test1" "" ".BackupDetails.BackupArn" "DDB_BACKUP_ARN"
validate_rewrite_smart "dynamodb describe-backup" "aws dynamodb describe-backup --backup-arn \$DDB_BACKUP_ARN" ""
validate_rewrite_smart "dynamodb list-backups" "aws dynamodb list-backups --table-name tf-combine-endpoints-test-gt" ""
validate_rewrite_smart "dynamodb delete-backup" "aws dynamodb delete-backup --backup-arn \$DDB_BACKUP_ARN" ""
validate_rewrite_smart "dynamodbstreams list-streams" "aws dynamodbstreams list-streams --table-name tf-combine-endpoints-test-gt --region us-iso-east-1" "" ".Streams[0].StreamArn" "STREAM_ARN"
validate_rewrite_smart "dynamodbstreams describe-stream" "aws dynamodbstreams describe-stream --stream-arn \$STREAM_ARN --region us-iso-east-1" "" ".StreamDescription.Shards[0].ShardId" "SHARD_ID"
validate_rewrite_smart "dynamodbstreams get-shard-iterator" "aws dynamodbstreams get-shard-iterator --stream-arn \$STREAM_ARN --shard-id \$SHARD_ID --shard-iterator-type LATEST --region us-iso-east-1" "" ".ShardIterator" "SHARD_ITERATOR_ID"
validate_rewrite_smart "dynamodbstreams get-records" "aws dynamodbstreams get-records --shard-iterator \$SHARD_ITERATOR_ID --region us-iso-east-1" "" ".NextShardIterator" "NEXT_SHARD_ITERATOR_ID"
validate_rewrite_smart "dynamodbstreams get-records (next iterator)" "aws dynamodbstreams get-records --shard-iterator \$NEXT_SHARD_ITERATOR_ID --region us-iso-east-1" ""

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

validate_expected_error_match "ec2 describe-instances (auth failure)" "aws ec2 describe-instances --region us-isob-east-1 --endpoint-url https://ec2.us-iso-east-1.c2s.ic.gov" "AWS was not able to validate the provided access credentials"

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
validate_rewrite_smart "glacier describe-vault" "aws glacier describe-vault --account-id 663117128738 --vault-name CombineTest" ""
validate_success "glacier set-vault-notifications" "aws glacier set-vault-notifications --account-id 663117128738 --vault-name CombineTest --vault-notification-config SNSTopic=arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest,Events=ArchiveRetrievalCompleted,InventoryRetrievalCompleted"
validate_rewrite_smart "glacier get-vault-notifications" "aws glacier get-vault-notifications --account-id 663117128738 --vault-name CombineTest" ""
validate_success "glacier delete-vault-notifications" "aws glacier delete-vault-notifications --account-id 663117128738 --vault-name CombineTest"
validate_success "glacier set-vault-access-policy" "aws glacier set-vault-access-policy --account-id 663117128738 --vault-name CombineTest --policy '{\"Policy\":\"{\\\"Version\\\": \\\"2012-10-17\\\",\\\"Statement\\\": [{\\\"Sid\\\": \\\"CombineTest\\\",\\\"Effect\\\": \\\"Allow\\\",\\\"Principal\\\": {\\\"AWS\\\": \\\"arn:aws-iso:iam::663117128738:root\\\"},\\\"Action\\\": \\\"glacier:*\\\",\\\"Resource\\\": \\\"arn:aws-iso:glacier:us-iso-east-1:663117128738:vaults/CombineTest\\\"}]}\"}'"
validate_rewrite_smart "glacier get-vault-access-policy" "aws glacier get-vault-access-policy --account-id 663117128738 --vault-name CombineTest" ""
validate_success "glacier delete-vault-access-policy" "aws glacier delete-vault-access-policy --account-id 663117128738 --vault-name CombineTest" 
validate_success "glacier initiate-vault-lock" "aws glacier initiate-vault-lock --account-id 663117128738 --vault-name CombineTest --policy '{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Sid\\\":\\\"CombineTest\\\",\\\"Principal\\\":\\\"*\\\",\\\"Effect\\\":\\\"Deny\\\",\\\"Action\\\":\\\"glacier:DeleteArchive\\\",\\\"Resource\\\":[\\\"arn:aws-iso:glacier:us-iso-east-1:663117128738:vaults/CombineTest\\\"],\\\"Condition\\\":{\\\"NumericLessThan\\\":{\\\"glacier:ArchiveAgeInDays\\\":\\\"7\\\"}}}]}\"}'"
validate_success "glacier get-vault-lock" "aws glacier get-vault-lock --account-id 663117128738 --vault-name CombineTest"
validate_success "glacier abort-vault-lock" "aws glacier abort-vault-lock --account-id 663117128738 --vault-name CombineTest"

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

validate_success "ssm put-parameter (SecureString)" "aws ssm put-parameter --name Test2 --value Test --type SecureString --key-id arn:aws-iso:kms:us-iso-east-1:663117128738:key/3000dcaa-c17a-4e5d-8e3a-5119afa0cf6f"
validate_success "ssm delete-parameter" "aws ssm delete-parameter --name Test2" ""

log ""
log "########################"
log "# 32. Glacier – Will fail (however we need to verify the endpoint logs through cloudwatch and I have no idea how to autoamte this currently, so commenting here.)"
log "########################"

validate_expected_error_match "glacier initiate-job (should fail)" "aws glacier initiate-job --account-id 663117128738 --vault-name CombineTest --job-parameters file://glacier_job.json" "ResourceNotFoundException"

log ""
log "########################"
log "# 33. ELBv2 Should fail, not implemented"
log "########################"

validate_expected_error_match "elbv2 create-load-balancer (not implemented)" "aws elbv2 create-load-balancer --name Foo --type network --subnet-mappings SubnetId=foo SubnetId=bar SubnetId=baz,PrivateIPv4Address=10.0.0.2" "Combine rejected this AWS API because it is not implemented"
validate_expected_error_match "elbv2 set-subnets (not implemented)" "aws elbv2 set-subnets --load-balancer-arn Foo --subnet-mappings SubnetId=foo SubnetId=bar SubnetId=baz,PrivateIPv4Address=10.0.0.2" "Combine rejected this AWS API because it is not implemented"
validate_expected_error_match "elbv2 create-load-balancer (security groups not implemented)" "aws elbv2 create-load-balancer --name Foo --type network --security-groups foo" "Combine rejected this AWS API because it is not implemented"
validate_expected_error_match "elbv2 set-security-groups (not implemented)" "aws elbv2 set-security-groups --load-balancer-arn foo --security-groups foo" "Combine rejected this AWS API because it is not implemented"

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
validate_success "cat presigned file content" "cat presign_copy_back.txt" "How is your monkey's uncle?" ##this fails because validate_s3 deletes the file need to find a way to incorporate this into the test.

log ""
log "########################"
log "# 36. S3 presign download - checksum match"
log "########################"

validate_s3 "s3 presign file.txt (checksum)" "file.txt" "foo/file.txt" "checksum"

log ""
log "########################"
log "# 37. S3 Location Constraint & Tagging Tests"
log "########################"

validate_success "s3api create-bucket" "aws s3api create-bucket --bucket sequoia-combine-test-location-constraint --create-bucket-configuration LocationConstraint=\"us-iso-east-1\""
validate_rewrite_smart "s3api get-bucket-location" "aws s3api get-bucket-location --bucket sequoia-combine-test-location-constraint" ""
validate_success "s3api put-bucket-tagging" "aws s3api put-bucket-tagging --bucket sequoia-combine-test-location-constraint --tagging \"TagSet=[{Key=foo,Value=bar}]\""
validate_success "s3api get-bucket-tagging" "aws s3api get-bucket-tagging --bucket sequoia-combine-test-location-constraint"
validate_success "s3api delete-bucket" "aws s3api delete-bucket --bucket sequoia-combine-test-location-constraint"

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
log "# 38. SQS Redrive Policy Failure and Cleanup"
log "########################"

validate_expected_error_match "sqs set-queue-attributes (nonexistent queues)" "aws sqs set-queue-attributes --queue-url \"https://sqs.us-iso-east-1.c2s.ic.gov/663117128738/bti360-horizon-sequoia-highlight-uploads-dlq\" --attributes '{\"RedriveAllowPolicy\":\"{\\\"redrivePermission\\\": \\\"byQueue\\\", \\\"sourceQueueArns\\\": [\\\"arn:aws-iso:sqs:us-iso-east-1:663117128738:nonexistent\\\",\\\"arn:aws-iso:sqs:us-iso-east-1:663117128738:also-nonexistent\\\",\\\"arn:aws-iso:sqs:us-iso-east-1:663117128738:lastly-nonexistent\\\"]}\"}'" "AWS.SimpleQueueService.NonExistentQueue"

validate_success "sqs delete-queue (Test2 cleanup)" "aws sqs delete-queue --queue-url https://sqs.us-iso-east-1.c2s.ic.gov/663117128738/Test2"

log ""
log "########################"
log "# 39. SQS ISO-B Queue Creation & Cleanup"
log "########################"

validate_rewrite_smart "sqs create-queue (ISO-B)" "aws sqs create-queue --queue-name TestB --attributes file://test_queue_isob.json --region us-isob-east-1 --endpoint-url https://sqs.us-isob-east-1.sc2s.sgov.gov"
validate_success "sqs delete-queue (ISO-B)" "aws sqs delete-queue --queue-url https://sqs.us-isob-east-1.sc2s.sgov.gov/663117128738/TestB --region us-isob-east-1 --endpoint-url https://sqs.us-isob-east-1.sc2s.sgov.gov"

log ""
log "########################"
log "# 40. S3 Bucket Policy Rewrite Validation"
log "########################"

validate_rewrite_smart "s3api put-bucket-policy" "aws s3api put-bucket-policy --bucket combine-endpoint-test --policy '{ \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"AWS\": \"arn:aws-iso:iam::770363063475:root\" }, \"Action\": [ \"s3:*\" ], \"Resource\": [ \"arn:aws-iso:s3:::combine-endpoint-test\", \"arn:aws-iso:s3:::combine-endpoint-test/*\" ] } ] }'"
validate_rewrite_smart "s3api get-bucket-policy" "aws s3api get-bucket-policy --bucket combine-endpoint-test"
validate_success "s3api delete-bucket-policy" "aws s3api delete-bucket-policy --bucket combine-endpoint-test"

log ""
log "########################"
log "# 41. EC2 describe-availability-zones"
log "########################"

validate_rewrite_smart "ec2 describe-availability-zones (filters by region and zone-id)" "aws ec2 describe-availability-zones --filters Name=region-name,Values=us-iso-east-1 Name=zone-id,Values=usie1-az1,usie1-az2"
validate_rewrite_smart "ec2 describe-availability-zones (zone-ids usie)" "aws ec2 describe-availability-zones --zone-ids usie1-az1 usie1-az2"
validate_rewrite_smart "ec2 describe-availability-zones (zone-ids usibe)" "aws ec2 describe-availability-zones --zone-ids usibe1-az1 usibe1-az2 --region us-isob-east-1"
validate_rewrite_smart "ec2 describe-availability-zones (zone-names us-iso)" "aws ec2 describe-availability-zones --zone-names us-iso-east-1a us-iso-east-1b"
validate_rewrite_smart "ec2 describe-availability-zones (zone-names us-isob)" "aws ec2 describe-availability-zones --zone-names us-isob-east-1a us-isob-east-1b --region us-isob-east-1"
validate_rewrite_smart "ec2 describe-availability-zones (filter by single zone-id usie)" "aws ec2 describe-availability-zones --filters Name=zone-id,Values=usie1-az1"
validate_rewrite_smart "ec2 describe-availability-zones (filter by single zone-id usibe)" "aws ec2 describe-availability-zones --filters Name=zone-id,Values=usibe1-az1 --region us-isob-east-1"
validate_rewrite_smart "ec2 describe-availability-zones (filter by zone-name us-iso)" "aws ec2 describe-availability-zones --filters Name=zone-name,Values=us-iso-east-1a"
validate_rewrite_smart "ec2 describe-availability-zones (filter by zone-name us-isob)" "aws ec2 describe-availability-zones --filters Name=zone-name,Values=us-isob-east-1a --region us-isob-east-1"

log ""
log "########################"
log "# 42. EC2 filtering and response validation"
log "########################"

validate_rewrite_smart "ec2 describe-subnets (filter: AZ, VPC, owner-id)" "aws ec2 describe-subnets --filters \"Name=owner-id,Values=663117128738\" \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\" \"Name=vpc-id,Values=\$VPC_ID\""
validate_rewrite_smart "ec2 describe-instances (filter: AZ, VPC, owner-id)" "aws ec2 describe-instances --filters \"Name=owner-id,Values=663117128738\" \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\" \"Name=vpc-id,Values=\$VPC_ID\""
validate_rewrite_smart "ec2 describe-instance-status (filter: AZ)" "aws ec2 describe-instance-status --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-volumes (filter: AZ)" "aws ec2 describe-volumes --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-volume-status (filter: AZ)" "aws ec2 describe-volume-status --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-reserved-instances (filter: AZ)" "aws ec2 describe-reserved-instances --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-reserved-instances-offerings (filter: AZ, max-items)" "aws ec2 describe-reserved-instances-offerings --max-items 10 --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-network-interfaces (filter: AZ)" "aws ec2 describe-network-interfaces --filters \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-capacity-reservations (filter: AZ)" "aws ec2 describe-capacity-reservations --filter \"Name=availability-zone,Values=us-iso-east-1a,us-iso-east-1b\""
validate_rewrite_smart "ec2 describe-availability-zones (region us-iso)" "aws ec2 describe-availability-zones --filters Name=region-name,Values=us-iso-east-1"
validate_rewrite_smart "ec2 describe-availability-zones (region us-isob)" "aws ec2 describe-availability-zones --filters Name=region-name,Values=us-isob-east-1 --region us-isob-east-1"

log ""
log "########################"
log "# 43. VPC endpoint service name rewriting"
log "########################"

validate_rewrite_smart "ec2 describe-vpc-endpoint-services (iso)" "aws ec2 describe-vpc-endpoint-services --service-names gov.ic.c2s.us-iso-east-1.elasticfilesystem"
validate_rewrite_smart "ec2 describe-vpc-endpoint-services (isob)" "aws ec2 describe-vpc-endpoint-services --service-names gov.sgov.sc2s.us-isob-east-1.elasticfilesystem --region us-isob-east-1"

log ""
log "########################"
log "# 44. Will pass, validate S3 service name"
log "########################"

validate_rewrite_smart "ec2 vpc-endpoint-services (iso)" "aws ec2 describe-vpc-endpoint-services --service-names com.amazonaws.us-iso-east-1.s3" ""
validate_rewrite_smart "ec2 vpc-endpoint-services (isob)" "aws ec2 describe-vpc-endpoint-services --service-names com.amazonaws.us-isob-east-1.s3 --region us-isob-east-1" ""

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

validate_expected_error_match "elasticache create-cache-cluster with encryption" "aws elasticache create-cache-cluster --cache-cluster-id foo --transit-encryption-enabled --region us-iso-east-1" "Combine rejected this AWS API"
validate_expected_error_match "elasticache create-replication-group with encryption" "aws elasticache create-replication-group --replication-group-id foo --replication-group-description foo --transit-encryption-enabled --region us-iso-east-1" "Combine rejected this AWS API"
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

validate_rewrite_smart "kinesis list-streams (TfCombineTest)" "aws kinesis list-streams" "" ".StreamSummaries[] | select(.StreamName==\"TfCombineTest\") | .StreamARN" "TF_KINESIS_ARN"
validate_rewrite_smart "kinesis describe-stream" "aws kinesis describe-stream --stream-arn \$TF_KINESIS_ARN" "" ".StreamDescription.StreamStatus"
validate_success "kinesis decrease-stream-retention" "aws kinesis decrease-stream-retention-period --stream-arn \$TF_KINESIS_ARN --retention-period-hours 24"

log ""
log "########################"
log "# 52. SWF Domain Tagging & Rewriting"
log "########################"

# Attempt to register domain, ignore if already exists
if aws swf register-domain --name CombineTest --workflow-execution-retention-period-in-days 1 2>&1 | grep -q "DomainAlreadyExistsFault"; then
  log "ℹ️  Domain CombineTest already exists. Attempting undeprecate."
  aws swf undeprecate-domain --name CombineTest >/dev/null 2>&1
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


validate_rewrite_smart "create-db-instance 2" "aws rds create-db-instance --master-username combineadmin --master-user-password Combine1275317 --db-subnet-group-name tf-combine-endpoints-test-subnet-group --db-instance-identifier CombineEndpointTestInstance2 --db-instance-class db.t3.micro --allocated-storage 8 --engine mysql --availability-zone us-iso-east-1a"
validate_rewrite_smart "create-db-cluster 2" "aws rds create-db-cluster --master-username combineadmin --master-user-password Combine1275317 --db-cluster-identifier CombineEndpointTestCluster2 --db-subnet-group-name tf-combine-endpoints-test-subnet-group --engine aurora-postgresql --availability-zones us-iso-east-1a us-iso-east-1b us-iso-east-1c"
validate_rewrite_smart "describe-db-instances" "aws rds describe-db-instances"
validate_rewrite_smart "describe-db-clusters" "aws rds describe-db-clusters"
validate_rewrite_smart "describe-db-subnet-groups" "aws rds describe-db-subnet-groups"
validate_rewrite_smart "delete-db-instance 2" "aws rds delete-db-instance --skip-final-snapshot --db-instance-identifier CombineEndpointTestInstance2"
validate_rewrite_smart "delete-db-cluster 2" "aws rds delete-db-cluster --skip-final-snapshot --db-cluster-identifier CombineEndpointTestCluster2"

log ""
log "########################"
log "# 54. RDS instance type will fail due to instance type"
log "########################"

validate_expected_error_match "unsupported RDS instance type" "aws rds create-db-instance --master-username combineadmin --master-user-password Combine1275317 --db-subnet-group-name tf-combine-endpoints-test-subnet-group --db-instance-identifier CombineEndpointTestInstanceInvalid --db-instance-class \$UNSUPPORTED_INSTANCE_TYPE --allocated-storage 8 --engine mysql --availability-zone us-iso-east-1a" "Combine rejected this AWS API"
validate_rewrite_smart "create-db-instance supported type" "aws rds create-db-instance --master-username combineadmin --master-user-password Combine1275317 --db-subnet-group-name tf-combine-endpoints-test-subnet-group --db-instance-identifier CombineEndpointTestInstance --db-instance-class db.m5.large --allocated-storage 8 --engine mysql --availability-zone us-iso-east-1a"
validate_success "delete-db-instance supported type" "aws rds delete-db-instance --skip-final-snapshot --db-instance-identifier CombineEndpointTestInstance"

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
validate_success "kms put-key-policy 4 (isob region)" "aws kms put-key-policy --key-id $KEY_ID --policy-name default --policy '{ \"Version\" : \"2012-10-17\", \"Id\" : \"key-default-1\", \"Statement\" : [ { \"Effect\" : \"Allow\", \"Principal\" : { \"AWS\":\"arn:aws-iso-b:iam::663117128738:root\", \"Service\" : \"ec2.sc2s.sgov.gov\" }, \"Action\" : \"kms:*\", \"Resource\" : \"*\" }, { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"ec2.sc2s.sgov.gov\" }, \"Action\": [ \"kms:Encrypt*\", \"kms:Decrypt*\", \"kms:ReEncrypt*\", \"kms:GenerateDataKey*\", \"kms:Describe*\", \"kms:List*\" ], \"Resource\": \"*\", \"Condition\": { \"StringEquals\": { \"kms:ViaService\": \"ec2.us-isob-east-1.sc2s.sgov.gov\" } } } ] }' --region us-isob-east-1"
validate_rewrite_smart "kms get-key-policy 4 (isob region)" "aws kms get-key-policy --key-id $KEY_ID --policy-name default"
validate_success "kms put-key-policy 5 (commercial ec2 test)" "aws kms put-key-policy --key-id $KEY_ID --policy-name default --policy '{ \"Version\" : \"2012-10-17\", \"Id\" : \"key-default-1\", \"Statement\" : [ { \"Effect\" : \"Allow\", \"Principal\" : { \"AWS\":\"arn:aws-iso-b:iam::663117128738:root\", \"Service\" : \"ec2.amazonaws.com\" }, \"Action\" : \"kms:*\", \"Resource\" : \"*\" }, { \"Effect\": \"Allow\", \"Principal\": { \"Service\": \"ec2.amazonaws.com\" }, \"Action\": [ \"kms:Encrypt*\", \"kms:Decrypt*\", \"kms:ReEncrypt*\", \"kms:GenerateDataKey*\", \"kms:Describe*\", \"kms:List*\" ], \"Resource\": \"*\", \"Condition\": { \"StringEquals\": { \"kms:ViaService\": \"ec2.us-isob-east-1.amazonaws.com\" } } } ] }' --region us-isob-east-1"
validate_rewrite_smart "kms get-key-policy 5 (commercial ec2 test)" "aws kms get-key-policy --key-id $KEY_ID --policy-name default"
validate_rewrite_smart "kms create-key" "aws kms create-key --policy '{ \"Version\" : \"2012-10-17\", \"Id\" : \"key-default-1\", \"Statement\" : [ { \"Effect\" : \"Allow\", \"Principal\" : { \"AWS\" : \"arn:aws-iso:iam::663117128738:root\" }, \"Action\" : \"kms:*\", \"Resource\" : \"*\" } ] }'" "" ".KeyMetadata.KeyId" "KEY_ID"
validate_success "kms create-grant" "aws kms create-grant --key-id \$KEY_ID --grantee-principal arn:aws-iso:iam::663117128738:role/Combine-Dev-TS-WLDEVELOPER --operations Decrypt --constraints EncryptionContextSubset={Department=IT} --retiring-principal arn:aws-iso:iam::663117128738:root" "__nonempty__"
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
else
  echo "❌ KMS encrypt/decrypt roundtrip failed (files do NOT match)"
  exit 1
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
validate_success "sqs list-dead-letter-source-queues" "aws sqs list-dead-letter-source-queues --queue-url https://sqs.us-iso-east-1.c2s.ic.gov/663117128738/combine-endpoints-test-dead-letter"

log ""
log "########################"
log "# 59. EC2 describe-instance-type-offerings plus verify unsuported type is not returned"
log "########################"

validate_rewrite_smart "ec2 describe-instance-type-offerings (default region)" "aws ec2 describe-instance-type-offerings"
validate_rewrite_smart "ec2 describe-instance-type-offerings (ISOB region)" "aws ec2 describe-instance-type-offerings --region us-isob-east-1"
validate_instance_type_absent_grep "instance-type-offerings (t2.nano filtering)" "aws ec2 describe-instance-type-offerings --filters Name=instance-type,Values=t2.nano,t2.micro,t3.nano" "t2.nano"

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

validate_success "cloudwatch put-metric-alarm (create alarm)" "aws cloudwatch put-metric-alarm --alarm-name CombineTest --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 300 --threshold 70 --comparison-operator GreaterThanThreshold --dimensions Name=InstanceId,Value=i-12345678912 --evaluation-periods 2 --ok-actions arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest --insufficient-data-actions arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest --alarm-actions arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest --unit Percent"
validate_rewrite_smart "cloudwatch describe-alarms (rewrite check)" "aws cloudwatch describe-alarms --action-prefix arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest"
validate_rewrite_smart "cloudwatch list-tags-for-resource (no tags expected)" "aws cloudwatch list-tags-for-resource --resource-arn arn:aws-iso:cloudwatch:us-iso-east-1:663117128738:alarm:TargetTracking-table/combine-endpoints-test-gt-AlarmLow-d7a4c741-a3fc-47ba-8986-65fa8fc454eb"
validate_success "cloudwatch delete-alarms" "aws cloudwatch delete-alarms --alarm-names CombineTest"
validate_rewrite_smart "cloudwatch describe-alarms (should be empty after delete)" "aws cloudwatch describe-alarms --action-prefix arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest"

log ""
log "########################"
log "# 64. KMS – FIPS endpoint rewrite validation"
log "########################"

validate_rewrite_smart "kms list-keys (fips endpoint)" "aws kms list-keys --endpoint-url https://kms-fips.us-iso-east-1.c2s.ic.gov"

log ""
log "########################"
log "# 65. CloudWatch Events rule and bus lifecycle"
log "########################"

validate_rewrite_smart "events create-event-bus" "aws events create-event-bus --name CombineTest"
validate_rewrite_smart "events describe-event-bus" "aws events describe-event-bus --name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest"
validate_rewrite_smart "events put-rule" "aws events put-rule --name CombineTest --event-pattern '{\"source\":[\"com.mycompany.myapp\"]}' --role-arn arn:aws-iso:iam::663117128738:role/CombineTestCWEventsRole --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest"
validate_rewrite_smart "events describe-rule" "aws events describe-rule --name CombineTest --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest"
validate_rewrite_smart "events put-targets" "aws events put-targets --rule CombineTest --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest --targets Id=Foo,Arn=arn:aws-iso:lambda:us-iso-east-1:663117128738:function:CombineTest"
validate_rewrite_smart "events list-targets-by-rule" "aws events list-targets-by-rule --rule CombineTest --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest"
validate_success "events put-events (events.json)" "aws events put-events --entries file://events.json"
validate_success "events remove-targets" "aws events remove-targets --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest --rule CombineTest --ids Foo"
validate_success "events delete-rule" "aws events delete-rule --name CombineTest --event-bus-name arn:aws-iso:events:us-iso-east-1:663117128738:event-bus/CombineTest"
validate_success "events delete-event-bus" "aws events delete-event-bus --name CombineTest"

log ""
log "########################"
log "# 66. CloudWatch Logs + disallowed KMS key usage"
log "########################"

validate_expected_error_match "logs associate-kms-key with disallowed KMS key" "aws logs associate-kms-key --log-group-name Foo --kms-key-id arn:aws-iso:kms:us-iso-east-1:663117128738:key/778b96a8-e41c-4a4d-a09e-368526bbf0d4" "is not allowed to be used with"
validate_expected_error_match "logs create-log-group with disallowed KMS key" "aws logs create-log-group --log-group-name KmsKeyTest --kms-key-id arn:aws-iso:kms:us-iso-east-1:663117128738:key/778b96a8-e41c-4a4d-a09e-368526bbf0d4" "is not allowed to be used with"

log ""
log "########################"
log "# 67. CloudWatch Logs - describe log groups and streams"
log "########################"

validate_rewrite_smart "logs describe-log-groups" "aws logs describe-log-groups --max-items 5"
validate_rewrite_smart "logs describe-log-streams" "aws logs describe-log-streams --log-group-name Combine_Dev_Log_Group_Endpoint --max-items 5"

log ""
log "########################"
log "# 68. Autoscaling group and notification validation"
log "########################"

validate_rewrite_smart "autoscaling describe-auto-scaling-groups" "aws autoscaling describe-auto-scaling-groups --region us-isob-east-1"
validate_rewrite_smart "autoscaling describe-auto-scaling-instances" "aws autoscaling describe-auto-scaling-instances --region us-isob-east-1"
validate_success "autoscaling put-notification-configuration" "aws autoscaling put-notification-configuration --auto-scaling-group-name Dev-Combine-ASG-Endpoints --topic-arn arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest --notification-types autoscaling:EC2_INSTANCE_LAUNCH"
validate_success "autoscaling delete-notification-configuration" "aws autoscaling delete-notification-configuration --auto-scaling-group-name Dev-Combine-ASG-Endpoints --topic-arn arn:aws-iso:sns:us-iso-east-1:663117128738:CombineEndpointsTest"

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

validate_expected_error_match "lambda create-function with invalid role ARN" "aws lambda create-function --function-name foo --role foo --vpc-config SubnetIds=\$SUBNET_1,\$SUBNET_2,\$SUBNET_3,SecurityGroupIds=foo" "Member must satisfy regular expression pattern: arn:"

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
validate_rewrite_smart "lambda add-permission from S3 arn" "aws lambda add-permission --function-name TfTest --statement-id TestArn --action lambda:InvokeFunction --principal s3.amazonaws.com --source-arn arn:aws-iso:s3:::combine-devops-370881201289"
validate_rewrite_smart "lambda add-permission from EMR" "aws lambda add-permission --function-name TfTest --statement-id TestServicePrincipal --action lambda:InvokeFunction --principal elasticmapreduce.c2s.ic.gov"
validate_rewrite_smart "lambda add-permission from EC2 optional" "aws lambda add-permission --function-name TfTest --statement-id TestServicePrincipalOptional --action lambda:InvokeFunction --principal ec2.c2s.ic.gov"
validate_rewrite_smart "lambda get-policy" "aws lambda get-policy --function-name TfTest"
validate_rewrite_smart "lambda create-alias" "aws lambda create-alias --function-name arn:aws-iso:lambda:us-iso-east-1:663117128738:function:TfTest --name TestAlias --function-version \$LATEST"
validate_rewrite_smart "lambda get-alias" "aws lambda get-alias --function-name arn:aws-iso:lambda:us-iso-east-1:663117128738:function:TfTest --name TestAlias"
validate_success "lambda delete-alias" "aws lambda delete-alias --function-name arn:aws-iso:lambda:us-iso-east-1:663117128738:function:TfTest --name TestAlias"
validate_rewrite_smart "lambda list-functions ALL" "aws lambda list-functions --function-version ALL"
validate_rewrite_smart "lambda list-functions master region" "aws lambda list-functions --master-region us-iso-east-1 --function-version ALL"

log ""
log "########################"
log "# 74. EC2 Run + Terminate Instance"
log "########################"

validate_rewrite_smart "ec2 run-instances" "aws ec2 run-instances --image-id ami-0d5eff06f840b45e9 --subnet-id $SUBNET_1 --instance-type t3.nano --placement AvailabilityZone=us-iso-east-1a" "" ".Instances[0].InstanceId" "EC2_INSTANCE_ID"
validate_success "ec2 terminate-instances" "aws ec2 terminate-instances --instance-ids $EC2_INSTANCE_ID" "shutting-down"

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
validate_rewrite_smart "efs put-file-system-policy" "aws efs put-file-system-policy --file-system-id \$FS_ID --policy file://efs-policy.json"
validate_rewrite_smart "efs describe-file-systems" "aws efs describe-file-systems"
validate_rewrite_smart "efs describe-file-system-policy" "aws efs describe-file-system-policy --file-system-id \$FS_ID"
validate_rewrite_smart "efs describe-access-points" "aws efs describe-access-points"
validate_success "efs delete-file-system" "aws efs delete-file-system --file-system-id \$FS_ID"

log ""
log "########################"
log "# 77. STS assume-role rewrite validation"
log "########################"

validate_rewrite_smart "sts assume-role (us-iso)" "aws sts assume-role --role-arn arn:aws-iso:iam::663117128738:role/Combine-TS-WLDEVELOPER --role-session-name Test"
validate_rewrite_smart "sts assume-role (us-isob)" "aws sts assume-role --role-arn arn:aws-iso-b:iam::663117128738:role/Combine-S-WLDEVELOPER --role-session-name Test" "us-isob-east-1"

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
validate_rewrite_smart "iam create-policy (us-isob)" "aws iam create-policy --policy-name Test --policy-document '{\"Statement\":[{\"Action\":[\"elasticfilesystem:DescribeMountTargets\",\"elasticfilesystem:ClientWrite\",\"elasticfilesystem:ClientRootAccess\",\"elasticfilesystem:ClientMount\"],\"Effect\":\"Allow\",\"Resource\":\"arn:aws-iso-b:elasticfilesystem:us-isob-east-1:123456789123:file-system/fs-11111111111111111\",\"Sid\":\"AllowRW\"}],\"Version\":\"2012-10-17\"}'" "us-isob-east-1"
validate_success "iam delete-policy (us-isob)" "aws iam delete-policy --policy-arn arn:aws-iso-b:iam::663117128738:policy/Test" "us-isob-east-1"

log ""
log "########################"
log "# 80. IAM policy create/delete with rewritten EFS ARNs"
log "########################"

validate_rewrite_smart "iam create-role with service principals" "aws iam get-role --role-name CombineTestServicePrincipal" "" ".Role.AssumeRolePolicyDocument.Statement[0].Principal.Service[]" "" "elasticfilesystem.amazonaws.com"
validate_success "iam delete-role" "aws iam delete-role --role-name CombineTestServicePrincipal"

log ""
log "########################"
log "# 81. IAM role creation with rewritten service principals"
log "########################"

validate_rewrite_smart "iam create-role with rewritten service principals" "aws iam create-role --role-name CombineTestServicePrincipal --assume-role-policy-document '{ \"Version\": \"2012-10-17\", \"Statement\": [ { \"Effect\": \"Allow\", \"Principal\": { \"Service\": [ \"elasticmapreduce.c2s.ic.gov\" ] }, \"Action\": \"sts:AssumeRole\" } ] }'"
validate_rewrite_smart "iam get-role with rewritten service principals" "aws iam get-role --role-name CombineTestServicePrincipal" "" ".Role.AssumeRolePolicyDocument.Statement[0].Principal.Service[]"
validate_success "iam delete-role" "aws iam delete-role --role-name CombineTestServicePrincipal"
