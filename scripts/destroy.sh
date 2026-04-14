#!/bin/bash
set -e

# Check if environment parameter is provided
if [ $# -eq 0 ]; then
    echo "❌ Error: Environment parameter is required"
    echo "Usage: $0 <environment>"
    echo "Example: $0 dev"
    echo "Available environments: dev, test, prod"
    exit 1
fi

ENVIRONMENT=$1
PROJECT_NAME=${2:-twin}
NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"

echo "🗑️ Preparing to destroy ${NAME_PREFIX} infrastructure..."

# Navigate to terraform directory
cd "$(dirname "$0")/../terraform"

# Get AWS Account ID and Region for backend configuration
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

# Initialize terraform with S3 backend
echo "🔧 Initializing Terraform with S3 backend..."
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

# Create workspace if it doesn't exist (instead of failing)
if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
    echo "⚠️  Workspace '$ENVIRONMENT' doesn't exist in remote backend. Creating it..."
    terraform workspace new "$ENVIRONMENT"
else
    terraform workspace select "$ENVIRONMENT"
fi

# Common terraform vars
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

# ══════════════════════════════════════════════════
# Phase 1: Import all known resources into state
# ══════════════════════════════════════════════════
echo "📥 Importing existing resources into Terraform state..."

MEMORY_BUCKET="${NAME_PREFIX}-memory-${AWS_ACCOUNT_ID}"
FRONTEND_BUCKET="${NAME_PREFIX}-frontend-${AWS_ACCOUNT_ID}"
LAMBDA_NAME="${NAME_PREFIX}-api"
LAMBDA_ROLE="${NAME_PREFIX}-lambda-role"

# S3 Buckets + sub-resources
try_import "aws_s3_bucket.memory" "${MEMORY_BUCKET}"
try_import "aws_s3_bucket.frontend" "${FRONTEND_BUCKET}"
try_import "aws_s3_bucket_public_access_block.memory" "${MEMORY_BUCKET}"
try_import "aws_s3_bucket_public_access_block.frontend" "${FRONTEND_BUCKET}"
try_import "aws_s3_bucket_ownership_controls.memory" "${MEMORY_BUCKET}"
try_import "aws_s3_bucket_website_configuration.frontend" "${FRONTEND_BUCKET}"
try_import "aws_s3_bucket_policy.frontend" "${FRONTEND_BUCKET}"

# IAM Role + policy attachments
try_import "aws_iam_role.lambda_role" "${LAMBDA_ROLE}"
try_import "aws_iam_role_policy_attachment.lambda_basic" "${LAMBDA_ROLE}/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
try_import "aws_iam_role_policy_attachment.lambda_bedrock" "${LAMBDA_ROLE}/arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
try_import "aws_iam_role_policy_attachment.lambda_s3" "${LAMBDA_ROLE}/arn:aws:iam::aws:policy/AmazonS3FullAccess"

# Lambda Function
try_import "aws_lambda_function.api" "${LAMBDA_NAME}"

# API Gateway — pick the first one found
API_GW_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${NAME_PREFIX}-api-gateway'].ApiId | [0]" --output text 2>/dev/null || true)
if [ -n "$API_GW_ID" ] && [ "$API_GW_ID" != "None" ]; then
  try_import "aws_apigatewayv2_api.main" "${API_GW_ID}"
  try_import "aws_apigatewayv2_stage.default" "${API_GW_ID}/\$default"

  INTEGRATION_ID=$(aws apigatewayv2 get-integrations --api-id "$API_GW_ID" --query "Items[0].IntegrationId" --output text 2>/dev/null || true)
  if [ -n "$INTEGRATION_ID" ] && [ "$INTEGRATION_ID" != "None" ]; then
    try_import "aws_apigatewayv2_integration.lambda" "${API_GW_ID}/${INTEGRATION_ID}"
  fi

  # Import routes by direct lookup
  import_route() {
    local tf_name="$1"
    local route_key="$2"
    local rid
    rid=$(aws apigatewayv2 get-routes --api-id "$API_GW_ID" \
      --query "Items[?RouteKey=='${route_key}'].RouteId | [0]" --output text 2>/dev/null || true)
    if [ -n "$rid" ] && [ "$rid" != "None" ]; then
      try_import "$tf_name" "${API_GW_ID}/${rid}"
    fi
  }
  import_route "aws_apigatewayv2_route.get_root"   "GET /"
  import_route "aws_apigatewayv2_route.post_chat"   "POST /chat"
  import_route "aws_apigatewayv2_route.get_health"  "GET /health"

  try_import "aws_lambda_permission.api_gw" "${LAMBDA_NAME}/AllowExecutionFromAPIGateway"
fi

# CloudFront — pick the first one found
CF_DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'${FRONTEND_BUCKET}')]].Id | [0]" \
  --output text 2>/dev/null || true)
if [ -n "$CF_DIST_ID" ] && [ "$CF_DIST_ID" != "None" ]; then
  try_import "aws_cloudfront_distribution.main" "${CF_DIST_ID}"
fi

# ══════════════════════════════════════════════════
# Phase 2: Empty S3 buckets (required before destroy)
# ══════════════════════════════════════════════════
echo "📦 Emptying S3 buckets..."
if aws s3 ls "s3://$FRONTEND_BUCKET" 2>/dev/null; then
    echo "  Emptying $FRONTEND_BUCKET..."
    aws s3 rm "s3://$FRONTEND_BUCKET" --recursive
fi
if aws s3 ls "s3://$MEMORY_BUCKET" 2>/dev/null; then
    echo "  Emptying $MEMORY_BUCKET..."
    aws s3 rm "s3://$MEMORY_BUCKET" --recursive
fi

# ══════════════════════════════════════════════════
# Phase 3: Terraform destroy
# ══════════════════════════════════════════════════
echo "🔥 Running terraform destroy..."

# Create a dummy lambda zip if it doesn't exist (needed for destroy plan)
if [ ! -f "../backend/lambda-deployment.zip" ]; then
    echo "  Creating dummy lambda package for destroy operation..."
    echo "dummy" | zip ../backend/lambda-deployment.zip -
fi

if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
    terraform destroy -var-file=prod.tfvars "${TF_COMMON_VARS[@]}" -auto-approve || true
else
    terraform destroy "${TF_COMMON_VARS[@]}" -auto-approve || true
fi

# ══════════════════════════════════════════════════
# Phase 4: Clean up DUPLICATE resources via AWS CLI
# (Terraform can only manage one per resource block,
#  so duplicates must be removed directly)
# ══════════════════════════════════════════════════
echo ""
echo "🧹 Cleaning up duplicate/orphaned resources..."

# --- Duplicate API Gateways ---
API_IDS=$(aws apigatewayv2 get-apis --query "Items[?Name=='${NAME_PREFIX}-api-gateway'].ApiId" --output text 2>/dev/null || true)
if [ -n "$API_IDS" ] && [ "$API_IDS" != "None" ]; then
  for api_id in $API_IDS; do
    echo "  Deleting orphaned API Gateway: $api_id"
    # Delete all routes first
    for route_id in $(aws apigatewayv2 get-routes --api-id "$api_id" --query "Items[*].RouteId" --output text 2>/dev/null); do
      aws apigatewayv2 delete-route --api-id "$api_id" --route-id "$route_id" 2>/dev/null || true
    done
    # Delete all integrations
    for int_id in $(aws apigatewayv2 get-integrations --api-id "$api_id" --query "Items[*].IntegrationId" --output text 2>/dev/null); do
      aws apigatewayv2 delete-integration --api-id "$api_id" --integration-id "$int_id" 2>/dev/null || true
    done
    # Delete all stages
    for stage_name in $(aws apigatewayv2 get-stages --api-id "$api_id" --query "Items[*].StageName" --output text 2>/dev/null); do
      aws apigatewayv2 delete-stage --api-id "$api_id" --stage-name "$stage_name" 2>/dev/null || true
    done
    # Delete the API itself
    aws apigatewayv2 delete-api --api-id "$api_id" 2>/dev/null || true
  done
fi

# --- Duplicate CloudFront Distributions ---
CF_DIST_IDS=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'${FRONTEND_BUCKET}')]].Id" \
  --output text 2>/dev/null || true)
if [ -n "$CF_DIST_IDS" ] && [ "$CF_DIST_IDS" != "None" ]; then
  for dist_id in $CF_DIST_IDS; do
    echo "  Disabling CloudFront distribution: $dist_id"
    # Get the current ETag and config
    ETAG=$(aws cloudfront get-distribution-config --id "$dist_id" --query "ETag" --output text 2>/dev/null || true)
    if [ -n "$ETAG" ] && [ "$ETAG" != "None" ]; then
      # Get config, disable it, and update
      aws cloudfront get-distribution-config --id "$dist_id" --query "DistributionConfig" > /tmp/cf-config.json 2>/dev/null || true
      if [ -f /tmp/cf-config.json ]; then
        # Set Enabled to false
        python3 -c "
import json
with open('/tmp/cf-config.json') as f:
    cfg = json.load(f)
cfg['Enabled'] = False
with open('/tmp/cf-config.json', 'w') as f:
    json.dump(cfg, f)
" 2>/dev/null || true
        aws cloudfront update-distribution --id "$dist_id" --if-match "$ETAG" --distribution-config file:///tmp/cf-config.json 2>/dev/null || true
        echo "  ⏳ Distribution $dist_id disabled. It will take ~15 min to fully deploy."
        echo "     After it's deployed, delete with: aws cloudfront delete-distribution --id $dist_id --if-match <NEW_ETAG>"
      fi
    fi
  done
fi

# --- Orphaned Lambda function ---
if aws lambda get-function --function-name "$LAMBDA_NAME" &>/dev/null; then
  echo "  Deleting orphaned Lambda: $LAMBDA_NAME"
  aws lambda delete-function --function-name "$LAMBDA_NAME" 2>/dev/null || true
fi

# --- Orphaned IAM Roles (old naming patterns) ---
for role_name in $(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PROJECT_NAME}-') && RoleName != '${LAMBDA_ROLE}'].RoleName" --output text 2>/dev/null || true); do
  if [ "$role_name" != "None" ] && [ -n "$role_name" ]; then
    echo "  Cleaning up orphaned IAM role: $role_name"
    # Detach all policies first
    for policy_arn in $(aws iam list-attached-role-policies --role-name "$role_name" --query "AttachedPolicies[*].PolicyArn" --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" 2>/dev/null || true
    done
    # Delete inline policies
    for policy_name in $(aws iam list-role-policies --role-name "$role_name" --query "PolicyNames" --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name" 2>/dev/null || true
    done
    aws iam delete-role --role-name "$role_name" 2>/dev/null || true
  fi
done

# Also clean up the lambda role itself if it still exists
if aws iam get-role --role-name "$LAMBDA_ROLE" &>/dev/null; then
  echo "  Cleaning up IAM role: $LAMBDA_ROLE"
  for policy_arn in $(aws iam list-attached-role-policies --role-name "$LAMBDA_ROLE" --query "AttachedPolicies[*].PolicyArn" --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$LAMBDA_ROLE" --policy-arn "$policy_arn" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$LAMBDA_ROLE" 2>/dev/null || true
fi

# ══════════════════════════════════════════════════
# Phase 5: Cleanup workspace
# ══════════════════════════════════════════════════
if [ "$ENVIRONMENT" != "default" ]; then
  echo "🗂️ Removing Terraform workspace..."
  terraform workspace select default 2>/dev/null || true
  terraform workspace delete "$ENVIRONMENT" 2>/dev/null || true
fi

echo ""
echo "✅ Destruction complete for ${NAME_PREFIX}!"
echo ""
echo "⚠️  Note: CloudFront distributions take ~15 minutes to disable."
echo "   Check their status with: aws cloudfront list-distributions --query \"DistributionList.Items[*].[Id,Status,Enabled]\" --output table"
echo "   Once 'Deployed' and 'False', delete them with:"
echo "   aws cloudfront delete-distribution --id <DIST_ID> --if-match <ETAG>"