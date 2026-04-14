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

# Import existing S3 buckets if not already in state
echo "📥 Checking for existing resources to import..."
MEMORY_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-memory-${AWS_ACCOUNT_ID}"
FRONTEND_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"

if ! terraform state show aws_s3_bucket.memory 2>/dev/null; then
  echo "Importing memory bucket..."
  terraform import "${TF_COMMON_VARS[@]}" aws_s3_bucket.memory "$MEMORY_BUCKET" 2>/dev/null || true
fi

if ! terraform state show aws_s3_bucket.frontend 2>/dev/null; then
  echo "Importing frontend bucket..."
  terraform import "${TF_COMMON_VARS[@]}" aws_s3_bucket.frontend "$FRONTEND_BUCKET" 2>/dev/null || true
fi

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