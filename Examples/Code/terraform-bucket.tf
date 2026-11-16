terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "bucket_name" {
  type        = string
  description = "Name of the bucket"
}

resource "aws_s3_bucket" "assets" {
  bucket = var.bucket_name
  tags   = { Environment = "dev", ManagedBy = "terraform" }
}

output "bucket_arn" {
  value = aws_s3_bucket.assets.arn
}
