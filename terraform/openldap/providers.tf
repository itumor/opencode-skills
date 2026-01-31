provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "global"
  region = var.global_accelerator_region
}
