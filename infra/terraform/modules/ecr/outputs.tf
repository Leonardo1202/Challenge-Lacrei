output "repository_url" { value = aws_ecr_repository.app.repository_url }
output "repository_arn" { value = aws_ecr_repository.app.arn }
output "registry_url"   { value = split("/", aws_ecr_repository.app.repository_url)[0] }
