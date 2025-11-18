output "sqs_queue_urls" {
  value = [
    aws_sqs_queue.tf_test_queue.id,
    aws_sqs_queue.tf_test_redrive.id
  ]
}

output "s3_bucket_name" {
  value = aws_s3_bucket.tf_test_bucket.bucket
}

output "iam_role_arn" {
  value = aws_iam_role.tf_combine_test_role.arn
}
