# K! gent

A serverless AI-powered digital twin application that creates a conversational replica of Keshav, hosted on their personal or professional website. Visitors can interact with the digital twin through a chat interface, and the system responds as if they were speaking with the real person, drawing from curated context including LinkedIn data, personal summaries, and communication style preferences.

## Table of Contents

- [Architecture](#architecture)
- [Technology Stack](#technology-stack)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
  - [Local Development](#local-development)
  - [Configuration](#configuration)
- [Deployment](#deployment)
  - [Initial AWS Setup](#initial-aws-setup)
  - [CI/CD Pipeline](#cicd-pipeline)
  - [Manual Deployment](#manual-deployment)
- [Infrastructure](#infrastructure)
  - [Terraform Resources](#terraform-resources)
  - [Environment Management](#environment-management)
- [API Reference](#api-reference)
- [License](#license)

## Architecture

```
User Browser
     |
     v
CloudFront (CDN)
     |
     +---> S3 (Static Frontend - Next.js)
     |
     +---> API Gateway (HTTP API)
                |
                v
          Lambda Function (FastAPI + Mangum)
                |
                +---> AWS Bedrock (LLM - Amazon Nova)
                +---> S3 (Conversation Memory)
```

The application follows a fully serverless architecture on AWS. The frontend is a statically exported Next.js application served through CloudFront and S3. The backend is a FastAPI application packaged for AWS Lambda using Mangum, fronted by API Gateway. Conversation history is persisted in S3, and language model inference is handled by AWS Bedrock.

## Technology Stack

| Layer          | Technology                              |
|----------------|----------------------------------------|
| Frontend       | Next.js 16, React 19, TypeScript, Tailwind CSS 4 |
| Backend        | Python 3.12, FastAPI, Mangum           |
| AI/ML          | AWS Bedrock (Amazon Nova)              |
| Infrastructure | Terraform, AWS (Lambda, API Gateway, S3, CloudFront) |
| CI/CD          | GitHub Actions, GitHub OIDC            |
| Package Mgmt   | npm (frontend), uv (backend)          |

## Project Structure

```
digital-twin/
├── backend/
│   ├── data/                  # Context data (LinkedIn PDF, facts, style, summary)
│   ├── server.py              # FastAPI application with chat endpoints
│   ├── lambda_handler.py      # AWS Lambda entry point (Mangum adapter)
│   ├── context.py             # System prompt construction
│   ├── resources.py           # Data file loaders (PDF, JSON, text)
│   ├── deploy.py              # Lambda packaging script (Docker-based)
│   ├── pyproject.toml         # Python dependencies
│   └── requirements.txt       # Pinned dependencies for Lambda
├── frontend/
│   ├── app/                   # Next.js App Router pages
│   ├── components/            # React components (chat interface)
│   ├── next.config.ts         # Static export configuration
│   └── package.json           # Node.js dependencies
├── terraform/
│   ├── main.tf                # Core infrastructure (S3, Lambda, API GW, CloudFront)
│   ├── github-oidc.tf         # GitHub Actions OIDC authentication
│   ├── variables.tf           # Input variable definitions
│   ├── outputs.tf             # Output values (URLs, bucket names)
│   ├── versions.tf            # Provider version constraints
│   └── terraform.tfvars       # Default variable values
├── scripts/
│   ├── deploy.sh              # Deployment automation (Linux/CI)
│   ├── deploy.ps1             # Deployment automation (Windows)
│   ├── destroy.sh             # Infrastructure teardown (Linux/CI)
│   └── destroy.ps1            # Infrastructure teardown (Windows)
├── .github/
│   └── workflows/
│       ├── deploy.yml         # CI/CD deployment workflow
│       └── destroy.yml        # Infrastructure destruction workflow
├── memory/                    # Local conversation storage (development)
├── .env.example               # Environment variable template
└── .gitignore
```

## Prerequisites

- **Python** 3.12 or later
- **Node.js** 20 or later
- **Docker** (required for building Lambda deployment packages)
- **Terraform** 1.0 or later
- **AWS CLI** configured with appropriate credentials
- **uv** (Python package manager) - https://docs.astral.sh/uv/
- An **AWS account** with Bedrock model access enabled

## Getting Started

### Local Development

1. Clone the repository:

   ```bash
   git clone https://github.com/keshavk21/digital-twin.git
   cd digital-twin
   ```

2. Set up the backend:

   ```bash
   cd backend
   cp .env.example .env
   # Edit .env with your AWS credentials and configuration
   uv sync
   uv run uvicorn server:app --reload --port 8000
   ```

3. Set up the frontend:

   ```bash
   cd frontend
   npm install
   npm run dev
   ```

   The frontend will be available at `http://localhost:3000` and will communicate with the backend at `http://localhost:8000`.

### Configuration

#### Backend Environment Variables

| Variable           | Description                                      | Default                          |
|--------------------|--------------------------------------------------|----------------------------------|
| `CORS_ORIGINS`     | Comma-separated list of allowed origins          | `http://localhost:3000`          |
| `DEFAULT_AWS_REGION` | AWS region for Bedrock and S3                  | `us-east-1`                     |
| `BEDROCK_MODEL_ID` | Bedrock model identifier                         | `global.amazon.nova-2-lite-v1:0` |
| `USE_S3`           | Use S3 for conversation storage (`true`/`false`) | `false`                          |
| `S3_BUCKET`        | S3 bucket name for conversation memory           | -                                |
| `MEMORY_DIR`       | Local directory for conversation storage         | `../memory`                      |

#### Personalizing the Digital Twin

The digital twin's personality and knowledge are defined by four data files in `backend/data/`:

| File            | Purpose                                         |
|-----------------|--------------------------------------------------|
| `facts.json`    | Structured personal information (name, role, etc.) |
| `summary.txt`   | Free-form notes and background context           |
| `style.txt`     | Communication style preferences                  |
| `Linkedin.pdf`  | LinkedIn profile export for professional context |

Replace these files with your own data to create your personalized digital twin.

## Deployment

### Initial AWS Setup

Before the first deployment, configure the following:

1. **S3 Backend for Terraform State**

   Create an S3 bucket and DynamoDB table for Terraform remote state:

   ```bash
   aws s3 mb s3://twin-terraform-state-<AWS_ACCOUNT_ID>
   aws dynamodb create-table \
     --table-name twin-terraform-locks \
     --attribute-definitions AttributeName=LockID,AttributeType=S \
     --key-schema AttributeName=LockID,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST
   ```

2. **GitHub OIDC Provider**

   Run Terraform locally with OIDC management enabled to create the IAM role for GitHub Actions:

   ```bash
   cd terraform
   terraform init
   terraform apply -var="manage_github_oidc=true" -var="project_name=twin" -var="environment=dev"
   ```

   Note the output `github_actions_role_arn` for the next step.

3. **GitHub Repository Secrets**

   Add the following secrets to your GitHub repository under Settings > Secrets and variables > Actions:

   | Secret               | Value                                    |
   |----------------------|------------------------------------------|
   | `AWS_ROLE_ARN`       | ARN of the GitHub Actions IAM role       |
   | `AWS_ACCOUNT_ID`     | Your 12-digit AWS account ID             |
   | `DEFAULT_AWS_REGION` | Target AWS region (e.g., `ap-south-1`)   |

### CI/CD Pipeline

The project uses GitHub Actions for automated deployment:

- **Deploy**: Triggered automatically on push to `main`, or manually via workflow dispatch. Supports `dev`, `test`, and `prod` environments.
- **Destroy**: Triggered manually via workflow dispatch with a confirmation step to prevent accidental destruction.

The deployment pipeline performs the following steps:

1. Builds the Lambda deployment package using Docker
2. Initializes Terraform with the S3 backend
3. Imports any existing AWS resources into the Terraform state
4. Applies the Terraform configuration
5. Builds the Next.js frontend as a static export
6. Syncs the frontend assets to S3
7. Invalidates the CloudFront cache

### Manual Deployment

To deploy manually from a local machine:

```bash
# Linux / macOS
./scripts/deploy.sh dev

# Windows (PowerShell)
.\scripts\deploy.ps1 dev
```

To destroy an environment:

```bash
# Linux / macOS
./scripts/destroy.sh dev

# Windows (PowerShell)
.\scripts\destroy.ps1 dev
```

## Infrastructure

### Terraform Resources

The infrastructure is defined across the following Terraform files:

| File              | Resources                                              |
|-------------------|--------------------------------------------------------|
| `main.tf`         | S3 buckets, IAM roles, Lambda, API Gateway, CloudFront, Route 53, ACM |
| `github-oidc.tf`  | GitHub OIDC provider and IAM role for CI/CD            |
| `variables.tf`    | Input variable definitions with validation             |
| `outputs.tf`      | Deployment URLs and resource identifiers               |
| `versions.tf`     | Terraform and provider version constraints             |
| `backend.tf`      | S3 backend configuration (populated at init time)      |

### Terraform Variables

| Variable                   | Description                        | Default                   |
|----------------------------|------------------------------------|---------------------------|
| `project_name`             | Name prefix for all resources      | -                         |
| `environment`              | Environment name (`dev`, `test`, `prod`) | -                   |
| `bedrock_model_id`         | Bedrock model identifier           | `amazon.nova-micro-v1:0`  |
| `lambda_timeout`           | Lambda timeout in seconds          | `60`                      |
| `api_throttle_burst_limit` | API Gateway burst limit            | `10`                      |
| `api_throttle_rate_limit`  | API Gateway rate limit             | `5`                       |
| `use_custom_domain`        | Attach a custom domain to CloudFront | `false`                 |
| `root_domain`              | Apex domain name                   | `""`                      |
| `manage_github_oidc`       | Manage OIDC resources (local only) | `false`                   |
| `github_repository`        | GitHub repo in `owner/repo` format | `keshavk21/digital-twin`  |

### Environment Management

The project supports multiple isolated environments using Terraform workspaces. Each environment deploys a complete, independent set of AWS resources with the naming convention `<project>-<environment>-<resource>`.

```bash
# List environments
terraform workspace list

# Create and switch to a new environment
terraform workspace new staging

# Destroy an environment
./scripts/destroy.sh staging
```

## API Reference

| Method | Endpoint                       | Description                              |
|--------|--------------------------------|------------------------------------------|
| GET    | `/`                            | Service information and status           |
| GET    | `/health`                      | Health check endpoint                    |
| POST   | `/chat`                        | Send a message and receive a response    |
| GET    | `/conversation/{session_id}`   | Retrieve conversation history by session |

### POST /chat

**Request Body:**

```json
{
  "message": "Tell me about your experience.",
  "session_id": "optional-uuid"
}
```

**Response:**

```json
{
  "response": "I have been working in...",
  "session_id": "generated-or-provided-uuid"
}
```

If `session_id` is omitted, a new session is created. Subsequent requests with the same `session_id` will include conversation history for context continuity.

## License

This project is private and not licensed for public use.
