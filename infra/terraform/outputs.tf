output "ecr_repository_url" {
  description = "URL completa do repositório ECR"
  value       = module.ecr.repository_url
}

output "ecr_registry" {
  description = "Registry ECR (sem o nome do repo) — usar como ECR_REGISTRY no GitHub"
  value       = module.ecr.registry_url
}

output "staging_instance_id" {
  description = "ID EC2 staging → GitHub Secret EC2_INSTANCE_ID_STAGING"
  value       = module.ec2_staging.instance_id
}

output "staging_public_ip" {
  description = "IP EC2 staging → DNS staging.cloudfy.solutions"
  value       = module.ec2_staging.public_ip
}

output "production_instance_id" {
  description = "ID EC2 produção → GitHub Secret EC2_INSTANCE_ID_PROD"
  value       = module.ec2_production.instance_id
}

output "production_public_ip" {
  description = "IP EC2 produção → DNS api.cloudfy.solutions"
  value       = module.ec2_production.public_ip
}

output "github_actions_role_arn" {
  description = "ARN IAM Role OIDC → GitHub Secret AWS_OIDC_ROLE_ARN"
  value       = module.iam.github_actions_role_arn
}

output "sns_topic_arn" {
  description = "ARN SNS → GitHub Secret SNS_ALERT_TOPIC_ARN"
  value       = module.sns.topic_arn
}

output "next_steps" {
  description = "Checklist pós-apply"
  value = <<-EOT

    ╔══════════════════════════════════════════════════════════╗
    ║           ✅  TERRAFORM APPLY CONCLUÍDO                  ║
    ╚══════════════════════════════════════════════════════════╝

    1. CONFIGURE O DNS no seu provedor (cloudfy.solutions):
       staging.cloudfy.solutions  →  A  →  ${module.ec2_staging.public_ip}
       api.cloudfy.solutions      →  A  →  ${module.ec2_production.public_ip}

    2. GITHUB SECRETS  (Settings → Secrets and variables → Actions):
       AWS_OIDC_ROLE_ARN         = ${module.iam.github_actions_role_arn}
       EC2_INSTANCE_ID_STAGING   = ${module.ec2_staging.instance_id}
       EC2_INSTANCE_ID_PROD      = ${module.ec2_production.instance_id}
       SNS_ALERT_TOPIC_ARN       = ${module.sns.topic_arn}

    3. GITHUB VARIABLES:
       AWS_REGION                = us-east-1
       ECR_REGISTRY              = ${module.ecr.registry_url}
       ECR_REPO                  = lacrei-status-api
       STAGING_URL               = https://staging.cloudfy.solutions
       PROD_URL                  = https://api.cloudfy.solutions

    4. APÓS DNS PROPAGAR — configure TLS:
       ./infra/scripts/setup-tls.sh staging
       ./infra/scripts/setup-tls.sh production

  EOT
}
