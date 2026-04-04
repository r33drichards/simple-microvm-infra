terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "simple-microvm-infra-tfstate"
    key    = "dns/terraform.tfstate"
    region = "us-west-2"
  }
}

provider "aws" {
  region = "us-west-2"
}

# Look up the existing hosted zone for robw.fyi
data "aws_route53_zone" "robw_fyi" {
  name = "robw.fyi."
}

# Hypervisor public IP
variable "hypervisor_ip" {
  description = "Public IP of the hypervisor"
  type        = string
  default     = "44.250.235.222"
}

# Twilio webhook subdomain → hypervisor
resource "aws_route53_record" "twilio" {
  zone_id = data.aws_route53_zone.robw_fyi.zone_id
  name    = "twilio.robw.fyi"
  type    = "A"
  ttl     = 300
  records = [var.hypervisor_ip]
}
