terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
        source = "hashicorp/aws"
        version = "~> 5.80"
    }
  }
  
}

provider "aws" {
    region = var.aws_region

    default_tags {
        tags ={
            Project = var.project_name
            ManagedBy = "terraform"
        }
    }
}

variable aws_region {
  type        = string
  default     = "ap-south-1"
  description = "AWS region to deploy into"
}

variable project_name {
  type        = string
  default     = "todo-capstone"
  description = "Prefix used for naming the AWS resource"
}

