# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.

output "url" {
  description = "HTTPS address of the API ($default stage)."
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "api_id" {
  description = "HTTP API ID."
  value       = aws_apigatewayv2_api.http.id
}

output "function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.app.function_name
}

output "alias_arn" {
  description = "ARN of the 'live' alias that serves traffic."
  value       = aws_lambda_alias.live.arn
}

output "site_url" {
  description = "HTTPS address of the static site."
  value       = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "site_bucket" {
  description = "Bucket that CI uploads the built site to."
  value       = aws_s3_bucket.site.bucket
}

output "site_distribution_id" {
  description = "CloudFront distribution that CI invalidates after it uploads the site."
  value       = aws_cloudfront_distribution.site.id
}

output "files_bucket" {
  description = "Bucket that holds the application's files (the students' data). It cannot be destroyed through this module."
  value       = aws_s3_bucket.files.bucket
}

output "files_kms_key_arn" {
  description = "Customer managed key that encrypts the files bucket, or null when files_kms_key is false. It cannot be destroyed through this module."
  value       = one(aws_kms_key.files[*].arn)
}

output "function_role_arn" {
  description = "Execution role of the function."
  value       = aws_iam_role.app.arn
}
