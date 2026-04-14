#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod
PROJECT_NAME=${2:-twin}

echo "🚀 Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# 1. Build Lambda package
cd "$(dirname "$0")/.."        # project root
echo "📦 Building Lambda package..."
(cd backend && uv run deploy.py)

# 2. Terraform workspace & apply
cd terraform
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace new "$ENVIRONMENT"
else
  terraform workspace select "$ENVIRONMENT"
fi

# Common terraform vars (OIDC resources are managed locally, not in CI/CD)
TF_COMMON_VARS=(-var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="manage_github_oidc=false" -input=false)

# Helper: import a resource if not already in state
try_import() {
  local resource_addr="$1"
  local resource_id="$2"
  if ! terraform state show "$resource_addr" &>/dev/null; then
    echo "  Importing $resource_addr..."
    terraform import "${TF_COMMON_VARS[@]}" "$resource_addr" "$resource_id" 2>/dev/null || true
  fi
}

# Import existing resources that may have been created by a previous local apply
echo "📥 Checking for existing resources to import..."
NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"

# S3 Buckets
try_import "aws_s3_bucket.memory" "${NAME_PREFIX}-memory-${AWS_ACCOUNT_ID}"
try_import "aws_s3_bucket.frontend" "${NAME_PREFIX}-frontend-${AWS_ACCOUNT_ID}"

# IAM Role for Lambda
try_import "aws_iam_role.lambda_role" "${NAME_PREFIX}-lambda-role"

# Lambda IAM policy attachments (format: role-name/policy-arn)
LAMBDA_ROLE="${NAME_PREFIX}-lambda-role"
try_import "aws_iam_role_policy_attachment.lambda_basic" "${LAMBDA_ROLE}/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
try_import "aws_iam_role_policy_attachment.lambda_bedrock" "${LAMBDA_ROLE}/arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
try_import "aws_iam_role_policy_attachment.lambda_s3" "${LAMBDA_ROLE}/arn:aws:iam::aws:policy/AmazonS3FullAccess"

# Use prod.tfvars for production environment
if [ "$ENVIRONMENT" = "prod" ]; then
  TF_APPLY_CMD=(terraform apply -var-file=prod.tfvars "${TF_COMMON_VARS[@]}" -auto-approve)
else
  TF_APPLY_CMD=(terraform apply "${TF_COMMON_VARS[@]}" -auto-approve)
fi

echo "🎯 Applying Terraform..."
"${TF_APPLY_CMD[@]}"

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)

# 3. Build + deploy frontend
cd ../frontend

# Create production environment file with API URL
echo "📝 Setting API URL for production..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

npm install
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# 4. Final messages
echo -e "\n✅ Deployment complete!"
echo "🌐 CloudFront URL : $(terraform -chdir=terraform output -raw cloudfront_url)"
if [ -n "$CUSTOM_URL" ]; then
  echo "🔗 Custom domain  : $CUSTOM_URL"
fi
echo "📡 API Gateway    : $API_URL"