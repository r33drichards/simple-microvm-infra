# GitHub Actions OIDC provider and IAM role
# Allows the terraform workflow to authenticate without static credentials

data "aws_caller_identity" "current" {}

# OIDC provider for GitHub Actions (may already exist in your account)
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"]
}

# IAM role that GitHub Actions assumes via OIDC
resource "aws_iam_role" "github_actions_terraform" {
  name = "github-actions-terraform-dns"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:r33drichards/simple-microvm-infra:*"
          }
        }
      }
    ]
  })
}

# Policy: allow Route 53 changes for the robw.fyi zone + S3 state bucket
resource "aws_iam_role_policy" "terraform_dns" {
  name = "terraform-dns-policy"
  role = aws_iam_role.github_actions_terraform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:GetHostedZone",
          "route53:ListHostedZones",
          "route53:ChangeResourceRecordSets",
          "route53:GetChange",
          "route53:ListResourceRecordSets",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::simple-microvm-infra-tfstate",
          "arn:aws:s3:::simple-microvm-infra-tfstate/*",
        ]
      },
    ]
  })
}

output "github_actions_role_arn" {
  description = "ARN of the IAM role for GitHub Actions"
  value       = aws_iam_role.github_actions_terraform.arn
}
