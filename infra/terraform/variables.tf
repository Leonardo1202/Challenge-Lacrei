variable "aws_region" {
  description = "AWS region para todos os recursos"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Nome do projeto (prefixo em todos os recursos)"
  type        = string
  default     = "lacrei"
}

variable "domain_staging" {
  description = "Domínio do ambiente de staging"
  type        = string
  default     = "staging.cloudfy.solutions"
}

variable "domain_production" {
  description = "Domínio do ambiente de produção"
  type        = string
  default     = "api.cloudfy.solutions"
}

variable "alert_email" {
  description = "E-mail para receber alertas via SNS"
  type        = string
}

variable "github_org" {
  description = "Usuário ou org do GitHub (OIDC trust policy)"
  type        = string
}

variable "github_repo" {
  description = "Nome do repositório GitHub"
  type        = string
  default     = "lacrei-devops-challenge"
}

variable "ami_id" {
  description = "AMI Ubuntu 22.04 LTS us-east-1"
  type        = string
  default     = "ami-0c7217cdde317cfec"
}

variable "vpc_cidr" {
  description = "CIDR block da VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "allowed_origins" {
  description = "Origins permitidas para CORS (separadas por vírgula)"
  type        = string
  default     = ""
}
