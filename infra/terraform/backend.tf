terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "lacrei-tfstate-149146127395"
    key            = "lacrei-devops/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "lacrei-tflock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "lacrei-devops-challenge"
      ManagedBy = "terraform"
    }
  }
}
