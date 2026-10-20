output "bucket_name" {
  description = "Artifacts bucket holding datasets and checkpoints"
  value       = aws_s3_bucket.artifacts.id
}

output "ecr_repository_url" {
  description = "ECR repo for the nanochat training image"
  value       = aws_ecr_repository.nanochat.repository_url
}
