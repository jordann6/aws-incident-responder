terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket       = "tf-backend-jord-projs"
    key          = "aws-incident-responder/lz.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Deploys into the landing zone's prod account, next to the workload it
# remediates, through the role exported from the LZ incident/ root.
provider "aws" {
  region = var.region

  assume_role {
    role_arn = var.deploy_role_arn
  }

  default_tags {
    tags = {
      Project     = "aws-incident-responder"
      Environment = "prod"
      Owner       = "jordan"
      ManagedBy   = "terraform"
      CostCenter  = "cc-0001"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
