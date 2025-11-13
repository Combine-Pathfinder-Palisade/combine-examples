
resource "aws_s3_bucket" "tf_test_bucket" {
  bucket = "sequoia-combine-test-location-constraint"
}


resource "aws_s3_bucket" "tf_test_bucket_2" {
  bucket = "tf-combine-test-permissions-bucket"
}

resource "aws_s3_bucket" "tf_cloudtrail_bucket" {
  bucket = "tf-cloudtrail-logs-${var.account_id}"
}

resource "aws_s3_bucket_policy" "tf_test_bucket_policy" {
  bucket = aws_s3_bucket.tf_test_bucket.id
  policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = {
        AWS = "arn:aws-iso:iam::${var.bucket_principal_arn}:root"
      }
      Action   = ["s3:*"]
      Resource = [
        "arn:aws-iso:s3:::${aws_s3_bucket.tf_test_bucket.id}",
        "arn:aws-iso:s3:::${aws_s3_bucket.tf_test_bucket.id}/*"
      ]
    }]
  })
}

resource "aws_s3_bucket_policy" "tf_cloudtrail_bucket_policy" {
  bucket = aws_s3_bucket.tf_cloudtrail_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "AWSCloudTrailAclCheck",
        Effect = "Allow",
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        },
        Action = "s3:GetBucketAcl",
        Resource = "arn:aws-iso:s3:::${aws_s3_bucket.tf_cloudtrail_bucket.id}"
      },
      {
        Sid = "AWSCloudTrailWrite",
        Effect = "Allow",
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        },
        Action = "s3:PutObject",
        Resource = "arn:aws-iso:s3:::${aws_s3_bucket.tf_cloudtrail_bucket.id}/EndpointsTest/AWSLogs/${var.account_id}/*",
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid = "AWSCloudTrailGetBucketLocation",
        Effect = "Allow",
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        },
        Action = "s3:GetBucketLocation",
        Resource = "arn:aws-iso:s3:::${aws_s3_bucket.tf_cloudtrail_bucket.id}"
      }
    ]
  })
}

resource "aws_s3_bucket_inventory" "test_inventory" {
  bucket = "tf-combine-test-permissions-bucket"
  name   = "Test"

  included_object_versions = "Current"
  enabled                  = true

  schedule {
    frequency = "Daily"
  }

  destination {
    bucket {
      format     = "CSV"
      bucket_arn = "arn:aws-iso:s3:::tf-combine-test-permissions-bucket"
      account_id = var.account_id
    }
  }
}

resource "aws_s3_bucket" "tF_test_bucket_west" {
  provider = aws.west
  bucket = "sequoia-combine-test-location-constraint-usiw1"
}

resource "aws_sqs_queue" "tf_test_queue" {
  name = "TfTest"
}

resource "aws_sqs_queue" "tf_test_redrive" {
  name = "TfTestRedrive"
}

resource "aws_sqs_queue" "tf_test2_queue" {
  name = "TfTest2"
}

resource "aws_sns_topic" "tf_s3_test_topic" {
  name = "TfS3Test"
}

resource "aws_sns_topic" "tf_test2_topic" {
  name = "TfTest2"
}

resource "aws_sns_topic_subscription" "tf_test2_subscription" {
  topic_arn = aws_sns_topic.tf_test2_topic.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.tf_test2_queue.arn
}

resource "aws_iam_role" "tf_combine_test_role" {
  name = "TfCombineTest"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = [
            "ec2.amazonaws.com",
            "lambda.amazonaws.com",
            "cloudtrail.amazonaws.com"
          ]
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "allow_cloudtrail_logs" {
  name = "AllowCloudTrailLogs"
  role = aws_iam_role.tf_combine_test_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "allow_ec2_actions" {
  name = "AllowEc2Actions"
  role = aws_iam_role.tf_combine_test_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "allow_sqs_send" {
  name = "AllowSQSSend"
  role = aws_iam_role.tf_combine_test_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [
          aws_sqs_queue.tf_test_queue.arn,
          aws_sqs_queue.tf_test_redrive.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "tf_combine_test_cw_events_role" {
  name = "TfCombineTestCWEventsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "events.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "tf_combine_test_policy" {
  name = "TfCombineTest"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:ListBucket"]
      Resource = "*"
    }]
  })
}

resource "aws_cloudwatch_log_group" "tf_log_group" {
  name              = "TF_CombineTest"
  retention_in_days = 7
}

resource "aws_cloudwatch_metric_alarm" "tf_combine_alarm" {
  alarm_name          = "TfCombineTest"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Test alarm"
  alarm_actions       = [aws_sns_topic.tf_test2_topic.arn]
  ok_actions          = [aws_sns_topic.tf_test2_topic.arn]
  insufficient_data_actions = [aws_sns_topic.tf_test2_topic.arn]
  dimensions = {
    InstanceId = "i-12345678912"
  }
}

resource "aws_ssm_parameter" "tf_test_secure_string" {
  name   = "TfTest2"
  type   = "SecureString"
  value  = "Test"
  key_id = aws_kms_key.tf_combine_key.arn
} #Evaluate this see if it uses the correct arn

resource "aws_dynamodb_table" "tf_combine_endpoints_test_gt" {
  name           = "tf-combine-endpoints-test-gt"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "test"

  attribute {
    name = "test"
    type = "S"
  }
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES" 
}

resource "aws_kms_key" "tf_combine_key" {
  description             = "Key for Combine endpoint testing"
  deletion_window_in_days = 7

  timeouts {
    create = "20m"
  }

  tags = {
    Name = "TfCombineTestKey"
  }
}

## Commented because it seems terraform tries to check if the policy returned is the same policy sent and it seems that we're returning something different or slightly different so it stalls TF LRM

resource "aws_kms_key_policy" "tf_combine_key_policy" {
  key_id = aws_kms_key.tf_combine_key.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "Enable IAM User Permissions",
        Effect = "Allow",
        Principal = {
          AWS = "arn:aws-iso:iam::${var.account_id}:root"
        },
        Action = "kms:*",
        Resource = "*"
      },
      {
        Sid = "Allow CloudTrail Use of the Key",
        Effect = "Allow",
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        },
        Action = [
          "kms:GenerateDataKey*",
          "kms:Encrypt"
        ],
        Resource = "*",
        Condition = {
          StringEquals = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws-iso:cloudtrail:us-iso-east-1:${var.account_id}:trail/TfCombineTest"
          }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "tf_combine_test_trail" {
  name                          = "TfCombineTest"
  s3_bucket_name                = aws_s3_bucket.tf_cloudtrail_bucket.bucket
  s3_key_prefix                 = "EndpointsTest"
  is_multi_region_trail         = false
  include_global_service_events = false
  cloud_watch_logs_group_arn    = "arn:aws-iso:logs:us-iso-east-1:${var.account_id}:log-group:TF_CombineTest:*"//aws_cloudwatch_log_group.tf_log_group.arn //"arn:aws-iso:logs:us-iso-east-1:${var.account_id}:log-group:CombineTest:*"
  cloud_watch_logs_role_arn     = aws_iam_role.tf_combine_test_role.arn //"arn:aws-iso:iam::${var.account_id}:role/service-role/CombineTestCloudTrailRole"
  kms_key_id                    = aws_kms_key.tf_combine_key.arn //"arn:aws-iso:kms:us-iso-east-1:${var.account_id}:key/3000dcaa-c17a-4e5d-8e3a-5119afa0cf6f"
}

resource "aws_db_subnet_group" "tf_combine_endpoints_subnet_group" {
  name       = "tf-combine-endpoints-test-subnet-group"
  subnet_ids = [
    var.subnet_1,
    var.subnet_2,
    var.subnet_3
  ]
}

resource "aws_rds_cluster" "tf_combine_cluster" {
  cluster_identifier      = "tf-combine-endpoint-test-cluster"
  engine                  = "aurora-postgresql"
  master_username         = "combineadmin"
  master_password         = "Combine1275317"
  db_subnet_group_name    = aws_db_subnet_group.tf_combine_endpoints_subnet_group.name
  availability_zones      = ["us-iso-east-1a", "us-iso-east-1b", "us-iso-east-1c"]
  skip_final_snapshot     = true
}

resource "aws_db_instance" "tf_combine_instance" {
  identifier              = "tf-combine-endpoint-test-instance"
  instance_class          = "db.t3.micro"
  engine                  = "mysql"
  engine_version          = "8.0.37" #seems engine needs to be specified in terraform or it will send a request with empty version
  allocated_storage       = 8
  username                = "combineadmin"
  password                = "Combine1275317"
  db_subnet_group_name    = aws_db_subnet_group.tf_combine_endpoints_subnet_group.name
  availability_zone       = "us-iso-east-1a"
  skip_final_snapshot     = true
}
##Load balancer creates but runs into issues with Combine on one of the update calls so commenting for now LRM
/*resource "aws_elb" "tf_combine_test_elb" {
  name               = "Foo"
  #availability_zones = ["us-iso-east-1a"]
  listener {
    instance_port     = 8080
    instance_protocol = "HTTP"
    lb_port           = 80
    lb_protocol       = "HTTP"
  }
  subnets  = [var.subnet_1]
}

resource "aws_lb" "tf_combine_lb" {
  name               = "Bar"
  internal           = true
  load_balancer_type = "application"
  subnets            = [var.subnet_1, var.subnet_2, var.subnet_3]
  enable_deletion_protection = false
  lifecycle {
    ignore_changes = all
  }
}

resource "aws_lb_target_group" "tf_combine_target_group" {
  name     = "TfBarTG"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id
}

resource "aws_lb_listener" "tf_combine_listener" {
  load_balancer_arn = aws_lb.tf_combine_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tf_combine_target_group.arn
  }
}*/

resource "aws_security_group" "lambda_sg" {
  name        = "combine-lambda-sg"
  description = "Security group for Lambda function"
  vpc_id      = var.vpc_id
}

resource "aws_lambda_function" "tf_combine_test_lambda" {
  function_name = "TFTest"
  role          = aws_iam_role.tf_combine_test_role.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  filename         = "${path.module}/dummy.zip" 
  source_code_hash = filebase64sha256("${path.module}/dummy.zip")
  vpc_config {
  	subnet_ids         = [var.subnet_1]
  	security_group_ids = [aws_security_group.lambda_sg.id]
  }
  dead_letter_config {
    target_arn = aws_sqs_queue.tf_test_redrive.arn
  }
}

resource "aws_lambda_permission" "tf_combine_test_lambda_permission_s3" {
  statement_id  = "TestArn"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tf_combine_test_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    =  aws_s3_bucket.tf_test_bucket_2.arn ##"arn:aws-iso:s3:::combine-devops-370881201289"
}

resource "aws_lambda_permission" "tf_combine_test_lambda_permission_emr" {
  statement_id  = "TestServicePrincipal"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tf_combine_test_lambda.function_name
  principal     = "elasticmapreduce.c2s.ic.gov"
}

resource "aws_lambda_permission" "tf_combine_test_lambda_permission_ec2" {
  statement_id  = "TestServicePrincipalOptional"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tf_combine_test_lambda.function_name
  principal     = "ec2.c2s.ic.gov"
}

resource "aws_kinesis_stream" "combine_test" {
  name             = "TfCombineTest"
  shard_count      = 1
  retention_period = 24
}

