terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "openldap-tfstate-083792476705"
    key            = "openldap-perf/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "openldap-tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region
}
