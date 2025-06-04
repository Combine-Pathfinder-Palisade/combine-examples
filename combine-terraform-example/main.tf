resource "aws_sqs_queue" "customer_terraform_queue" {
  name                        = "customer_terraform_queue.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  policy = jsonencode({
  "Id": "SQSPESendPolicy",
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "SQS:SendMessage",
      "Effect": "Allow",
      "Principal": {
        "AWS": "*"
      },
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "arn:aws-iso:sns:us-iso-east-1:123456789012:foo"
        }
      },
      "Resource": "arn:aws-iso:sqs:us-iso-east-1:123456789012:renderedai_terraform_queue.fifo"
    }
  ]
})
}