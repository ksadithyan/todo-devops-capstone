data "aws_caller_identity" "current" {}
# 1. Two ECR Repositories (Frontend + Backend) with Scan-on-Push
resource "aws_ecr_repository" "frontend" {
  name         = "${var.project_name}-frontend"
  force_delete = true
  image_scanning_configuration {
    scan_on_push = true
  }
}
resource "aws_ecr_repository" "backend" {
  name         = "${var.project_name}-backend"
  force_delete = true
  image_scanning_configuration {
    scan_on_push = true
  }
}
# 2. SNS Topic & Email Subscription (click the confirm link in your inbox after apply)
resource "aws_sns_topic" "ecr_alerts" {
  name = "${var.project_name}-ecr-alerts"
}
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.ecr_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
# 3. S3 Bucket for CloudTrail Logs (force_destroy = true lets terraform destroy clean it up)
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project_name}-cloudtrail-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = true
}
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}
# 4. CloudTrail recording write events (captures ECR PutImage into S3)
resource "aws_cloudtrail" "ecr" {
  name                          = "${var.project_name}-ecr-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = false
  is_multi_region_trail         = false
  event_selector {
    read_write_type           = "WriteOnly"
    include_management_events = true
  }
  depends_on = [aws_s3_bucket_policy.cloudtrail]
}
# 5. Lambda IAM Role & Permissions
resource "aws_iam_role" "ecr_notify_lambda" {
  name = "${var.project_name}-ecr-notify-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.ecr_notify_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "ecr_notify_lambda" {
  name = "${var.project_name}-ecr-notify-policy"
  role = aws_iam_role.ecr_notify_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.cloudtrail.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:DescribeImages", "ecr:DescribeImageScanFindings"]
        Resource = [aws_ecr_repository.frontend.arn, aws_ecr_repository.backend.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.ecr_alerts.arn
      }
    ]
  })
}
# 6. Package & Deploy Lambda
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/notify.py"
  output_path = "${path.module}/../lambda/notify.zip"
}
resource "aws_lambda_function" "ecr_notify" {
  function_name    = "${var.project_name}-ecr-notify"
  role             = aws_iam_role.ecr_notify_lambda.arn
  handler          = "notify.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30
  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.ecr_alerts.arn
      ALLOWED_REPOS = "${aws_ecr_repository.frontend.name},${aws_ecr_repository.backend.name}"
    }
  }
}
# 7. Trigger Lambda when CloudTrail drops a log file into S3
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ecr_notify.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.cloudtrail.arn
}
resource "aws_s3_bucket_notification" "cloudtrail_to_lambda" {
  bucket = aws_s3_bucket.cloudtrail.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.ecr_notify.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "AWSLogs/"
    filter_suffix       = ".json.gz"
  }
  depends_on = [aws_lambda_permission.allow_s3]
}
output "ecr_frontend_url" {
  value = aws_ecr_repository.frontend.repository_url
}
output "ecr_backend_url" {
  value = aws_ecr_repository.backend.repository_url
}
