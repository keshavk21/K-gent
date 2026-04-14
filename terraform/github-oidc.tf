# This creates an IAM role that GitHub Actions can assume
# These resources are managed locally, NOT by CI/CD (set manage_github_oidc = true locally)

variable "github_repository" {
  description = "GitHub repository in format 'owner/repo'"
  type        = string
  default     = "keshavk21/digital-twin"
}

variable "manage_github_oidc" {
  description = "Whether to manage GitHub OIDC resources (set true only for local apply, false in CI/CD)"
  type        = bool
  default     = false
}

# Note: aws_caller_identity.current is already defined in main.tf

# GitHub OIDC Provider
resource "aws_iam_openid_connect_provider" "github" {
  count = var.manage_github_oidc ? 1 : 0

  url = "https://token.actions.githubusercontent.com"
  
  client_id_list = [
    "sts.amazonaws.com"
  ]
  
  # This thumbprint is from GitHub's documentation
  thumbprint_list = [
    "1b511abead59c6ce207077c0bf0e0043b1382612"
  ]
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions" {
  count = var.manage_github_oidc ? 1 : 0

  name = "github-actions-twin-deploy"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github[0].arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:*"
          }
        }
      }
    ]
  })
  
  tags = {
    Name        = "GitHub Actions Deploy Role"
    Repository  = var.github_repository
    ManagedBy   = "terraform"
  }
}

# Attach necessary policies
resource "aws_iam_role_policy_attachment" "github_lambda" {
  count      = var.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_s3" {
  count      = var.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_apigateway" {
  count      = var.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_cloudfront" {
  count      = var.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/CloudFrontFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_iam_read" {
  count      = var.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/IAMReadOnlyAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_bedrock" {
  count      = var.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_dynamodb" {
  count      = var.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_acm" {
  count      = var.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AWSCertificateManagerFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_route53" {
  count      = var.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
  role       = aws_iam_role.github_actions[0].name
}

# Custom policy for additional permissions
resource "aws_iam_role_policy" "github_additional" {
  count = var.manage_github_oidc ? 1 : 0
  name  = "github-actions-additional"
  role  = aws_iam_role.github_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:UpdateAssumeRolePolicy",
          "iam:PassRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListInstanceProfilesForRole",
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  value = var.manage_github_oidc ? aws_iam_role.github_actions[0].arn : ""
}