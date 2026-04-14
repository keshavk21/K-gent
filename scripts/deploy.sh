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

# ── S3 Buckets ──
MEMORY_BUCKET="${NAME_PREFIX}-memory-${AWS_ACCOUNT_ID}"
FRONTEND_BUCKET="${NAME_PREFIX}-frontend-${AWS_ACCOUNT_ID}"
try_import "aws_s3_bucket.memory" "${MEMORY_BUCKET}"
try_import "aws_s3_bucket.frontend" "${FRONTEND_BUCKET}"

# S3 sub-resources (keyed by bucket name)
try_import "aws_s3_bucket_public_access_block.memory" "${MEMORY_BUCKET}"
try_import "aws_s3_bucket_public_access_block.frontend" "${FRONTEND_BUCKET}"
try_import "aws_s3_bucket_ownership_controls.memory" "${MEMORY_BUCKET}"
try_import "aws_s3_bucket_website_configuration.frontend" "${FRONTEND_BUCKET}"
try_import "aws_s3_bucket_policy.frontend" "${FRONTEND_BUCKET}"

# ── IAM Role for Lambda ──
LAMBDA_ROLE="${NAME_PREFIX}-lambda-role"
try_import "aws_iam_role.lambda_role" "${LAMBDA_ROLE}"

# Lambda IAM policy attachments (format: role-name/policy-arn)
try_import "aws_iam_role_policy_attachment.lambda_basic" "${LAMBDA_ROLE}/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
try_import "aws_iam_role_policy_attachment.lambda_bedrock" "${LAMBDA_ROLE}/arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
try_import "aws_iam_role_policy_attachment.lambda_s3" "${LAMBDA_ROLE}/arn:aws:iam::aws:policy/AmazonS3FullAccess"

# ── Lambda Function ──
LAMBDA_NAME="${NAME_PREFIX}-api"
try_import "aws_lambda_function.api" "${LAMBDA_NAME}"

# ── API Gateway ──
# Look up existing API Gateway by name
API_GW_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${NAME_PREFIX}-api-gateway'].ApiId | [0]" --output text 2>/dev/null || true)
if [ -n "$API_GW_ID" ] && [ "$API_GW_ID" != "None" ]; then
  try_import "aws_apigatewayv2_api.main" "${API_GW_ID}"
  try_import "aws_apigatewayv2_stage.default" "${API_GW_ID}/\$default"

  # Import integrations
  INTEGRATION_ID=$(aws apigatewayv2 get-integrations --api-id "$API_GW_ID" --query "Items[0].IntegrationId" --output text 2>/dev/null || true)
  if [ -n "$INTEGRATION_ID" ] && [ "$INTEGRATION_ID" != "None" ]; then
    try_import "aws_apigatewayv2_integration.lambda" "${API_GW_ID}/${INTEGRATION_ID}"
  fi

  # Import routes
  for ROUTE_KEY_ENCODED in $(aws apigatewayv2 get-routes --api-id "$API_GW_ID" --query "Items[*].[RouteId,RouteKey]" --output text 2>/dev/null | while read -r rid rkey_rest; do echo "${rid}:${rkey_rest}"; done); do
    ROUTE_ID=$(echo "$ROUTE_KEY_ENCODED" | cut -d: -f1)
    ROUTE_KEY=$(echo "$ROUTE_KEY_ENCODED" | cut -d: -f2-)
    case "$ROUTE_KEY" in
      "GET /")       try_import "aws_apigatewayv2_route.get_root"   "${API_GW_ID}/${ROUTE_ID}" ;;
      "POST /chat")  try_import "aws_apigatewayv2_route.post_chat"  "${API_GW_ID}/${ROUTE_ID}" ;;
      "GET /health") try_import "aws_apigatewayv2_route.get_health" "${API_GW_ID}/${ROUTE_ID}" ;;
    esac
  done

  # Import Lambda permission for API Gateway
  try_import "aws_lambda_permission.api_gw" "${LAMBDA_NAME}/AllowExecutionFromAPIGateway"
fi

# ── CloudFront Distribution ──
# Find distribution by looking for our S3 origin
CF_DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'${FRONTEND_BUCKET}')]].Id | [0]" \
  --output text 2>/dev/null || true)
if [ -n "$CF_DIST_ID" ] && [ "$CF_DIST_ID" != "None" ]; then
  try_import "aws_cloudfront_distribution.main" "${CF_DIST_ID}"
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