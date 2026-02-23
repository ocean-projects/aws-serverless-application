terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0.0"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.region
}

# =========================================================
# S3 STATIC SITE (PRIVATE)
# =========================================================

resource "aws_s3_bucket" "static_site_bucket" {
  bucket        = "ocean-site-bucket-0983"
  force_destroy = true

  tags = {
    Name = "Static site bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "static_site_public_access_block" {
  bucket                  = aws_s3_bucket.static_site_bucket.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "static_site_bucket_versioning" {
  bucket = aws_s3_bucket.static_site_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "static_site_bucket_lifecycle_config" {
  bucket = aws_s3_bucket.static_site_bucket.id

  rule {
    id     = "rule-1"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 60
      storage_class = "GLACIER"
    }

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.static_site_bucket.id
  key          = "index.html"
  source       = "${path.module}/html/index.html"
  content_type = "text/html"
}

resource "aws_s3_object" "error_html" {
  bucket       = aws_s3_bucket.static_site_bucket.id
  key          = "error.html"
  source       = "${path.module}/html/error.html"
  content_type = "text/html"
}

# =========================================================
# CLOUDFRONT + ORIGIN ACCESS CONTROL
# =========================================================

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "static-site-oac"
  description                       = "OAC for private S3 static site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "static_site" {
  enabled             = true
  comment             = "Static site distribution (S3 private via OAC)"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.static_site_bucket.bucket_regional_domain_name
    origin_id                = "s3-static-site-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-static-site-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Bucket policy allowing CloudFront ONLY

data "aws_iam_policy_document" "static_site_bucket_policy" {
  statement {
    sid     = "AllowCloudFrontReadOnly"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    resources = [
      "${aws_s3_bucket.static_site_bucket.arn}/*"
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.static_site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "static_site_policy" {
  bucket = aws_s3_bucket.static_site_bucket.id
  policy = data.aws_iam_policy_document.static_site_bucket_policy.json
}

# =========================================================
# DYNAMODB
# =========================================================

resource "aws_dynamodb_table" "feedback" {
  name         = "feedback"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = {
    Name = "Feedback table"
  }
}

# =========================================================
# IAM ROLE FOR LAMBDA
# =========================================================

resource "aws_iam_role" "lambda_exec" {
  name = "feedback-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_dynamodb_policy" {
  name = "feedback-lambda-dynamodb"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.feedback.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# =========================================================
# LAMBDA
# =========================================================

data "archive_file" "lambda_feedback_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda/feedback.zip"
}

resource "aws_lambda_function" "feedback" {
  function_name = "feedback-handler"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"

  filename         = data.archive_file.lambda_feedback_zip.output_path
  source_code_hash = data.archive_file.lambda_feedback_zip.output_base64sha256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.feedback.name
    }
  }
}

# =========================================================
# API GATEWAY
# =========================================================

resource "aws_apigatewayv2_api" "feedback_api" {
  name          = "feedback-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.feedback_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.feedback.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_feedback" {
  api_id    = aws_apigatewayv2_api.feedback_api.id
  route_key = "POST /feedback"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "get_health" {
  api_id    = aws_apigatewayv2_api.feedback_api.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.feedback_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.feedback.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.feedback_api.execution_arn}/*/*"
}

# =========================================================
# OUTPUTS
# =========================================================

output "static_website_endpoint" {
  value = "https://${aws_cloudfront_distribution.static_site.domain_name}"
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.static_site.domain_name
}

output "feedback_api_endpoint" {
  value = "${aws_apigatewayv2_api.feedback_api.api_endpoint}/feedback"
}