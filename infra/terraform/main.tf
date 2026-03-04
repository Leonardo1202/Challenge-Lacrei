# ── SNS ───────────────────────────────────────────────────────────────────────
module "sns" {
  source      = "./modules/sns"
  project     = var.project
  alert_email = var.alert_email
}

# ── ECR ───────────────────────────────────────────────────────────────────────
module "ecr" {
  source  = "./modules/ecr"
  project = var.project
}

# ── IAM ───────────────────────────────────────────────────────────────────────
module "iam" {
  source      = "./modules/iam"
  project     = var.project
  aws_region  = var.aws_region
  github_org  = var.github_org
  github_repo = var.github_repo
  ecr_arn     = module.ecr.repository_arn
  sns_arn     = module.sns.topic_arn
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source     = "./modules/vpc"
  project    = var.project
  vpc_cidr   = var.vpc_cidr
  aws_region = var.aws_region
}

# ── EC2 STAGING ───────────────────────────────────────────────────────────────
module "ec2_staging" {
  source               = "./modules/ec2"
  project              = var.project
  environment          = "staging"
  instance_type        = "t3.micro"
  ami_id               = var.ami_id
  subnet_id            = module.vpc.public_subnet_id
  vpc_id               = module.vpc.vpc_id
  iam_instance_profile = module.iam.ec2_instance_profile_name
  aws_region           = var.aws_region
  allowed_origins      = var.allowed_origins
  ecr_registry         = module.ecr.registry_url
}

# ── EC2 PRODUCTION ────────────────────────────────────────────────────────────
module "ec2_production" {
  source               = "./modules/ec2"
  project              = var.project
  environment          = "production"
  instance_type        = "t3.small"
  ami_id               = var.ami_id
  subnet_id            = module.vpc.public_subnet_id
  vpc_id               = module.vpc.vpc_id
  iam_instance_profile = module.iam.ec2_instance_profile_name
  aws_region           = var.aws_region
  allowed_origins      = var.allowed_origins
  ecr_registry         = module.ecr.registry_url
}

# ── CloudWatch ────────────────────────────────────────────────────────────────
module "cloudwatch" {
  source              = "./modules/cloudwatch"
  project             = var.project
  aws_region          = var.aws_region
  sns_topic_arn       = module.sns.topic_arn
  staging_instance_id = module.ec2_staging.instance_id
  prod_instance_id    = module.ec2_production.instance_id
}
