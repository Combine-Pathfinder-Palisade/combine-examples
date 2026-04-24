output "s3_bucket_name" {
  value = aws_s3_bucket.tf_test_bucket.bucket
}

output "s3_bucket_permissions" {
  value = aws_s3_bucket.tf_test_bucket_2.bucket
}

output "s3_bucket_cloudtrail" {
  value = aws_s3_bucket.tf_cloudtrail_bucket.bucket
}

output "s3_bucket_west" {
  value = aws_s3_bucket.tf_test_bucket_west.bucket
}

output "sqs_queue_urls" {
  value = [
    aws_sqs_queue.tf_test_queue.id,
    aws_sqs_queue.tf_test_redrive.id
  ]
}

output "sqs_queue_2_url" {
  value = aws_sqs_queue.tf_test2_queue.id
}

output "sns_topic_s3_arn" {
  value = aws_sns_topic.tf_s3_test_topic.arn
}

output "sns_topic_2_arn" {
  value = aws_sns_topic.tf_test2_topic.arn
}

output "iam_role_arn" {
  value = aws_iam_role.tf_combine_test_role.arn
}

output "iam_role_cw_events_arn" {
  value = aws_iam_role.tf_combine_test_cw_events_role.arn
}

output "iam_policy_arn" {
  value = aws_iam_policy.tf_combine_test_policy.arn
}

output "cloudwatch_log_group_name" {
  value = aws_cloudwatch_log_group.tf_log_group.name
}

output "cloudwatch_alarm_name" {
  value = aws_cloudwatch_metric_alarm.tf_combine_alarm.alarm_name
}

output "ssm_parameter_name" {
  value = aws_ssm_parameter.tf_test_secure_string.name
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.tf_combine_endpoints_test_gt.name
}

output "dynamodb_table_stream_arn" {
  value = aws_dynamodb_table.tf_combine_endpoints_test_gt.stream_arn
}

output "kms_key_arn" {
  value = aws_kms_key.tf_combine_key.arn
}

output "kms_key_id" {
  value = aws_kms_key.tf_combine_key.key_id
}

output "cloudtrail_arn" {
  value = aws_cloudtrail.tf_combine_test_trail.arn
}

output "rds_cluster_endpoint" {
  value = aws_rds_cluster.tf_combine_cluster.endpoint
}

output "rds_cluster_arn" {
  value = aws_rds_cluster.tf_combine_cluster.arn
}

output "rds_instance_endpoint" {
  value = aws_db_instance.tf_combine_instance.endpoint
}

output "rds_instance_arn" {
  value = aws_db_instance.tf_combine_instance.arn
}

output "lambda_function_arn" {
  value = aws_lambda_function.tf_combine_test_lambda.arn
}

output "lambda_function_name" {
  value = aws_lambda_function.tf_combine_test_lambda.function_name
}

output "security_group_id" {
  value = aws_security_group.lambda_sg.id
}

output "kinesis_stream_arn" {
  value = aws_kinesis_stream.combine_test.arn
}

output "kinesis_stream_name" {
  value = aws_kinesis_stream.combine_test.name
}
