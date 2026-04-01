#!/bin/bash
set -e

# Store original directory
ORIGINAL_DIR=$(pwd)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ENVIRONMENT=""
VPC_ID=""
SEPARATE_SUBNETS=false
AWS_REGION="us-iso-east-1"
CLUSTER_NAME=""
TERRAGRUNT_DIR=""
SKIP_EKS_AUTH=false
AWS_ACCOUNT_ID=""

# Arrays for subnets
NODE_SUBNET_IDS=()
POD_SUBNET_IDS=()
ALL_SUBNET_IDS=()

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
usage() {
    cat << EOF
Usage: $0 -e ENVIRONMENT -v VPC_ID [OPTIONS]

Create and deploy EKS cluster with optional custom networking (separated pod/node subnets)

Required:
  -e, --environment   Environment name (e.g., combine-ss-test, combine-jposada-eks)
  -v, --vpc-id        VPC ID to deploy cluster into (e.g., vpc-028ce6d4d021c36dc)

Optional:
  -n, --separate-nets Enable custom networking with separate pod/node subnets
  -r, --region        AWS region (default: us-iso-east-1)
  -a, --skip-auth     Skip eks-auth module deployment (default: false)
  -h, --help          Show this help message

Examples:
  # Regular EKS cluster (like combine-jposada-eks structure)
  $0 -e my-cluster -v vpc-028ce6d4d021c36dc

  # EKS cluster with custom networking (like combine-ss-test structure)
  $0 -e my-cluster -v vpc-028ce6d4d021c36dc -n

  # With custom region
  $0 -e my-cluster -v vpc-028ce6d4d021c36dc -n -r us-east-1
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -v|--vpc-id)
            VPC_ID="$2"
            shift 2
            ;;
        -n|--separate-nets)
            SEPARATE_SUBNETS=true
            shift
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -a|--skip-auth)
            SKIP_EKS_AUTH=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$ENVIRONMENT" ]]; then
    print_error "Environment name is required"
    usage
    exit 1
fi

if [[ -z "$VPC_ID" ]]; then
    print_error "VPC ID is required"
    usage
    exit 1
fi

# Set derived variables
CLUSTER_NAME="combine-${ENVIRONMENT}-eks"
if [[ "$SEPARATE_SUBNETS" = true ]]; then
    TERRAGRUNT_DIR="terragrunt/${ENVIRONMENT}/eks-cluster-separate-subnets"
    MODULE_TYPE="eks-cluster-separate-subnets"
else
    TERRAGRUNT_DIR="terragrunt/${ENVIRONMENT}/eks-cluster"
    MODULE_TYPE="eks-cluster"
fi

print_status "Starting EKS deployment setup..."
print_status "Environment: $ENVIRONMENT"
print_status "VPC ID: $VPC_ID"
print_status "Custom networking: $SEPARATE_SUBNETS"
print_status "Cluster: $CLUSTER_NAME"
print_status "Region: $AWS_REGION"
print_status "Terragrunt dir: $TERRAGRUNT_DIR"

# Step 1: Check prerequisites
print_status "Checking prerequisites..."

# Check if we're in the right directory
if [[ ! -f "README.md" ]] || [[ ! -d "modules" ]]; then
    print_error "Please run this script from the root directory"
    exit 1
fi

# # Check required tools
# for tool in terragrunt aws kubectl jq; do
#     if ! command -v $tool &> /dev/null; then
#         print_error "$tool is not installed or not in PATH"
#         exit 1
#     fi
# done

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured or invalid"
    exit 1
fi

# Get AWS Account ID
print_status "Retrieving AWS Account ID..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [[ -z "$AWS_ACCOUNT_ID" ]]; then
    print_error "Failed to retrieve AWS Account ID"
    exit 1
fi
print_success "AWS Account ID: $AWS_ACCOUNT_ID"

# Step 2: Discover subnets in the VPC
print_status "Discovering subnets in VPC $VPC_ID..."

# Get all non-RESTRICTED subnets from the VPC
SUBNET_DATA=$(aws ec2 describe-subnets \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[?!(starts_with(Tags[?Key==`Name`]|[0].Value, `RESTRICTED`))].{SubnetId:SubnetId, Name:Tags[?Key==`Name`]|[0].Value, CIDR:CidrBlock, AZ:AvailabilityZone}' \
    --output json)

if [[ -z "$SUBNET_DATA" ]] || [[ "$SUBNET_DATA" == "[]" ]]; then
    print_error "No suitable subnets found in VPC $VPC_ID"
    exit 1
fi

# Parse subnet data and organize by AZ
print_status "Analyzing subnet layout..."
echo "$SUBNET_DATA" | jq -r '.[] | "\(.AZ) \(.SubnetId) \(.Name) \(.CIDR)"' | sort

# Extract subnet IDs into arrays
ALL_SUBNET_IDS=($(echo "$SUBNET_DATA" | jq -r '.[].SubnetId'))

if [[ "$SEPARATE_SUBNETS" = true ]]; then
    # For custom networking: separate subnets by naming pattern
    # Assume pattern: *-AZ-A1, *-AZ-B1, *-AZ-C1 for nodes
    #                *-AZ-A2, *-AZ-B2, *-AZ-C2 for pods

    NODE_SUBNET_IDS=($(echo "$SUBNET_DATA" | jq -r '.[] | select(.Name | test(".*-AZ-[ABC]1$")) | .SubnetId'))
    POD_SUBNET_IDS=($(echo "$SUBNET_DATA" | jq -r '.[] | select(.Name | test(".*-AZ-[ABC]2$")) | .SubnetId'))

    if [[ ${#NODE_SUBNET_IDS[@]} -eq 0 ]] || [[ ${#POD_SUBNET_IDS[@]} -eq 0 ]]; then
        print_warning "Could not detect subnet pattern for custom networking"
        print_status "Available subnets:"
        echo "$SUBNET_DATA" | jq -r '.[] | "  \(.SubnetId) - \(.Name) (\(.AZ))"'

        # Fallback: split subnets evenly
        TOTAL_SUBNETS=${#ALL_SUBNET_IDS[@]}
        HALF_COUNT=$((TOTAL_SUBNETS / 2))

        NODE_SUBNET_IDS=("${ALL_SUBNET_IDS[@]:0:$HALF_COUNT}")
        POD_SUBNET_IDS=("${ALL_SUBNET_IDS[@]:$HALF_COUNT}")

        print_warning "Using fallback subnet allocation:"
        print_status "Node subnets: ${NODE_SUBNET_IDS[*]}"
        print_status "Pod subnets: ${POD_SUBNET_IDS[*]}"
    else
        print_success "Detected subnet pattern for custom networking:"
        print_status "Node subnets (AZ-*1): ${NODE_SUBNET_IDS[*]}"
        print_status "Pod subnets (AZ-*2): ${POD_SUBNET_IDS[*]}"
    fi
else
    # For regular EKS: use all available subnets
    NODE_SUBNET_IDS=("${ALL_SUBNET_IDS[@]}")
    print_status "Using all available subnets: ${NODE_SUBNET_IDS[*]}"
fi

print_success "Subnet discovery completed"

# Step 3: Create S3 bucket for Terraform state if it doesn't exist
print_status "Checking/creating S3 bucket for Terraform state..."

ENV_LOWER=$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')
STATE_BUCKET="${ENV_LOWER}-${AWS_REGION}.tfstate"

print_status "S3 state bucket: $STATE_BUCKET"

if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
    print_success "S3 bucket $STATE_BUCKET already exists"
else
    print_status "Creating S3 bucket: $STATE_BUCKET"

    # us-iso-east-1 doesn't need LocationConstraint
    if [[ "$AWS_REGION" == "us-iso-east-1" ]]; then
        aws s3api create-bucket --bucket "$STATE_BUCKET"
    else
        aws s3api create-bucket \
            --bucket "$STATE_BUCKET" \
            --region "$AWS_REGION" \
            --acl private \
            --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi

    if [[ $? -eq 0 ]]; then
        print_success "Created S3 bucket: $STATE_BUCKET"

        aws s3api put-bucket-ownership-controls \
            --bucket "$STATE_BUCKET" \
            --ownership-controls '{
                "Rules": [
                { "ObjectOwnership": "ObjectWriter" }
                ]
            }'

        # Configure bucket security
        aws s3api put-bucket-versioning \
            --bucket "$STATE_BUCKET" \
            --versioning-configuration Status=Enabled

        # NOTE: command not currently working in combine. checksum error.
        aws s3api put-bucket-encryption \
            --bucket "$STATE_BUCKET" \
            --region "$AWS_REGION" \
            --server-side-encryption-configuration '{
                "Rules": [
                    {
                        "ApplyServerSideEncryptionByDefault": {
                            "SSEAlgorithm": "aws:kms"
                        },
                        "BucketKeyEnabled": false
                    }
                ]
            }'

        aws s3api put-public-access-block \
            --bucket "$STATE_BUCKET" \
            --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

        print_success "$STATE_BUCKET S3 bucket configured!"
    else
        print_error "Failed to create S3 bucket: $STATE_BUCKET"
        exit 1
    fi
fi

# # Check/create DynamoDB table for state locking
# print_status "Checking/creating DynamoDB table for Terraform state locking..."
# LOCK_TABLE="terraform-locks"

# if aws dynamodb describe-table --table-name "$LOCK_TABLE" &>/dev/null; then
#     print_success "DynamoDB table $LOCK_TABLE already exists"
# else
#     print_status "Creating DynamoDB table: $LOCK_TABLE"
#     aws dynamodb create-table \
#         --table-name "$LOCK_TABLE" \
#         --attribute-definitions AttributeName=LockID,AttributeType=S \
#         --key-schema AttributeName=LockID,KeyType=HASH \
#         --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5

#     if [[ $? -eq 0 ]]; then
#         print_success "Created DynamoDB table: $LOCK_TABLE"
#         aws dynamodb wait table-exists --table-name "$LOCK_TABLE"
#         print_success "DynamoDB table is ready"
#     else
#         print_error "Failed to create DynamoDB table: $LOCK_TABLE"
#         exit 1
#     fi
# fi

# Step 4: Handle terragrunt directory structure
print_status "Checking terragrunt configuration..."

SKIP_CREATION=false

# Check if terragrunt configuration already exists
if [[ -f "terragrunt/${ENVIRONMENT}/env.hcl" ]] || [[ -f "$TERRAGRUNT_DIR/terragrunt.hcl" ]]; then
    print_success "Found existing terragrunt configuration for environment: $ENVIRONMENT"
    echo
    print_status "What would you like to do?"
    echo "  1) Use existing configuration and continue with deployment"
    echo "  2) Recreate configuration files (overwrites existing)"
    echo "  3) Exit and deploy manually"
    echo
    read -p "Choose option (1-3): " -n 1 -r
    echo

    case $REPLY in
        1)
            print_success "Using existing configuration - skipping file creation"
            SKIP_CREATION=true
            ;;
        2)
            print_warning "Will recreate all configuration files..."
            SKIP_CREATION=false
            ;;
        3)
            print_status "To deploy existing configuration manually, run:"
            print_status "  cd $TERRAGRUNT_DIR && terragrunt apply"
            exit 0
            ;;
        *)
            print_status "Invalid choice. Using existing configuration by default."
            SKIP_CREATION=true
            ;;
    esac
fi

# Create terragrunt structure only if needed
if [[ "$SKIP_CREATION" = false ]]; then
    print_status "Creating terragrunt directory structure..."

# Create base environment directory
mkdir -p "terragrunt/${ENVIRONMENT}"

# Create env.hcl file
print_status "Creating env.hcl..."
cat > "terragrunt/${ENVIRONMENT}/env.hcl" << EOF
locals {
  aws_account_id   = "${AWS_ACCOUNT_ID}"
  ecr_account_id   = local.aws_account_id
  ecr_collection   = "combine-eks"
  environment      = "${ENVIRONMENT}"
  resource_prefix  = local.environment
  default_aws_tags = {
    "environment" = local.environment
  }

  aws_region        = "${AWS_REGION}"
  aws_endpoint      = "c2s.ic.gov"
  aws_profile       = "WLDEVELOPER"
  aws_state_profile = "WLDEVELOPER"

  is_combine_env   = true
  aws_ca_cert_path = "/home/ec2-user/combine-${ENVIRONMENT}/certificates/ca-chain.cert.pem"
}
EOF

# Create module-specific directory and terragrunt.hcl
mkdir -p "$TERRAGRUNT_DIR"

print_status "Creating ${MODULE_TYPE}/terragrunt.hcl..."
if [[ "$SEPARATE_SUBNETS" = true ]]; then
    # Create terragrunt.hcl for custom networking (matching combine-ss-test pattern)
    # Format subnet arrays properly for HCL
    NODE_SUBNET_LIST=""
    for i in "${!NODE_SUBNET_IDS[@]}"; do
        if [[ $i -eq 0 ]]; then
            NODE_SUBNET_LIST="    \"${NODE_SUBNET_IDS[$i]}\","
        else
            NODE_SUBNET_LIST+="\n    \"${NODE_SUBNET_IDS[$i]}\","
        fi
    done

    POD_SUBNET_LIST=""
    for i in "${!POD_SUBNET_IDS[@]}"; do
        if [[ $i -eq 0 ]]; then
            POD_SUBNET_LIST="    \"${POD_SUBNET_IDS[$i]}\","
        else
            POD_SUBNET_LIST+="\n    \"${POD_SUBNET_IDS[$i]}\","
        fi
    done

    cat > "${TERRAGRUNT_DIR}/terragrunt.hcl" << EOF
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "\${include.root.locals.module_base_source_url}//eks-cluster-separate-subnets\${include.root.locals.module_base_version}"
}

locals {
  aws_region  = include.root.locals.aws_region
  aws_profile = include.root.locals.aws_profile
}

inputs = {
  vpc_id = "${VPC_ID}"
  # Node subnets: where EC2 nodes / primary ENIs live
  # have access to VPC endpoints for AWS services
  node_subnet_ids = [
$(echo -e "$NODE_SUBNET_LIST")
  ]
  # Pod subnets: where application pods will be placed
  # should NOT have access to VPC endpoints
  pod_subnet_ids = [
$(echo -e "$POD_SUBNET_LIST")
  ]

  encryption_config                     = {}
  cluster_encryption_config                     = {}
  cluster_security_group_additional_cidr_blocks = ["10.0.0.0/16"]
  cluster_name                                  = "combine-\${include.root.locals.environment_vars.environment}-eks"
  cluster_version                               = "1.30"
  cluster_endpoint_public_access                = false

  cluster_admin_arn = "arn:aws:iam::\${include.root.locals.environment_vars.aws_account_id}:role/Combine-\${include.root.locals.environment_vars.environment}-TS-WLDEVELOPER"

  combine_ca_chain_b64 = base64encode(file(include.root.locals.environment_vars.aws_ca_cert_path))

  node_group_remote_access_key = "Combine${ENVIRONMENT}"

  iam_role_permissions_boundary_arn = "arn:aws-iso:iam::\${include.root.locals.environment_vars.aws_account_id}:policy/PB-\${include.root.locals.environment_vars.environment}-WLDEVELOPER-C2E-TS"

  tags = {}
}
EOF
else
    # Create terragrunt.hcl for regular EKS (matching combine-jposada-eks pattern)
    # Format subnet array properly for HCL
    SUBNET_LIST=""
    for i in "${!NODE_SUBNET_IDS[@]}"; do
        if [[ $i -eq 0 ]]; then
            SUBNET_LIST="    \"${NODE_SUBNET_IDS[$i]}\","
        else
            SUBNET_LIST+="\n    \"${NODE_SUBNET_IDS[$i]}\","
        fi
    done

    cat > "${TERRAGRUNT_DIR}/terragrunt.hcl" << EOF
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "\${include.root.locals.module_base_source_url}//eks-cluster\${include.root.locals.module_base_version}"
}

locals {
  aws_region  = include.root.locals.aws_region
  aws_profile = include.root.locals.aws_profile
}

inputs = {
  vpc_id = "${VPC_ID}"
  subnet_ids = [
$(echo -e "$SUBNET_LIST")
  ]

  cluster_encryption_config                     = {}
  cluster_security_group_additional_cidr_blocks = ["10.0.0.0/16"]
  cluster_name                                  = "combine-\${include.root.locals.environment_vars.environment}-eks"
  cluster_version                               = "1.30"
  cluster_endpoint_public_access                = false
  cluster_addons                                = {}

  cluster_admin_arn = "arn:aws:iam::\${include.root.locals.environment_vars.aws_account_id}:role/Combine-\${include.root.locals.environment_vars.environment}-TS-WLDEVELOPER"

  combine_ca_chain_b64 = base64encode(file(include.root.locals.environment_vars.aws_ca_cert_path))

  node_group_remote_access_key = "Combine${ENVIRONMENT}"

  iam_role_permissions_boundary_arn = "arn:aws-iso:iam::\${include.root.locals.environment_vars.aws_account_id}:policy/PB-\${include.root.locals.environment_vars.environment}-WLDEVELOPER-C2E-TS"

  tags = {}
}
EOF
fi

# Create additional required modules based on the pattern
if [[ "$SEPARATE_SUBNETS" = false ]]; then
    # For regular EKS, create additional modules like combine-jposada-eks

    # Create eks-auth directory
    mkdir -p "terragrunt/${ENVIRONMENT}/eks-auth"
    cat > "terragrunt/${ENVIRONMENT}/eks-auth/terragrunt.hcl" << 'EOF'
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.module_base_source_url}//eks-auth${include.root.locals.module_base_version}"
}

dependency "eks_cluster" {
  config_path  = "../eks-cluster"
  mock_outputs = include.root.locals.common_vars.mock_outputs.eks_cluster
}

locals {
  aws_region  = include.root.locals.aws_region
  aws_profile = include.root.locals.aws_profile
}

inputs = {

  cluster_name                       = dependency.eks_cluster.outputs.cluster_name
  cluster_endpoint                   = dependency.eks_cluster.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks_cluster.outputs.cluster_certificate_authority_data

  node_group_role_arns = dependency.eks_cluster.outputs.node_group_role_arns
  admin_role_arns      = ["arn:aws-iso:iam::${include.root.locals.aws_account_id}:role/Combine-${include.root.locals.environment_vars.environment}-TS-WLDEVELOPER"]
  admin_users = [
    {
      username = "developer-combine-jposada"
      arn      = "arn:aws-iso:iam::${include.root.locals.aws_account_id}:user/developer-combine-jposada"
    }
  ]
  cluster_certificate_authority_data = dependency.eks_cluster.outputs.cluster_certificate_authority_data
  cluster_endpoint                   = dependency.eks_cluster.outputs.cluster_endpoint
  cluster_name                       = dependency.eks_cluster.outputs.cluster_name
}
EOF

    # Create oidc-provider directory
    mkdir -p "terragrunt/${ENVIRONMENT}/oidc-provider"
    cat > "terragrunt/${ENVIRONMENT}/oidc-provider/terragrunt.hcl" << 'EOF'
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.module_base_source_url}//oidc-provider${include.root.locals.module_base_version}"
}

generate "provider_oidc" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<PROVIDER_EOF
      variable "default_tags" {
        type = map(any)
      }
provider "aws" {
  region = "\${include.root.locals.aws_region}"
  profile = "\${local.aws_profile}"
  default_tags {
    tags = var.default_tags
  }
}
PROVIDER_EOF
}

dependency "eks_cluster" {
  config_path  = "../eks-cluster"
  mock_outputs = include.root.locals.common_vars.mock_outputs.eks_cluster
}

locals {
  aws_profile = "WLCUSTOMERIT"
}

inputs = {
  aws_profile             = local.aws_profile
  cluster_name            = dependency.eks_cluster.outputs.cluster_name
  cluster_oidc_issuer_url = dependency.eks_cluster.outputs.cluster_oidc_issuer_url
  client_id_list          = ["sts.amazonaws.com"]
}
EOF

    # Create plugins directory
    mkdir -p "terragrunt/${ENVIRONMENT}/plugins"
    cat > "terragrunt/${ENVIRONMENT}/plugins/terragrunt.hcl" << 'EOF'
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.module_base_source_url}//plugins${include.root.locals.module_base_version}"
}

generate "lbc-helmignore" {
  path      = "modules/aws-load-balancer-controller/charts/aws-load-balancer-controller/1.8.1/.helmignore"
  if_exists = "overwrite_terragrunt"
  contents  = <<HELMIGNORE_EOF
.terragrunt-source-manifest*
HELMIGNORE_EOF
}

generate "ebs-csi-helmignore" {
  path      = "modules/ebs-csi-driver/charts/aws-ebs-csi-driver/2.33.0/.helmignore"
  if_exists = "overwrite_terragrunt"
  contents  = <<HELMIGNORE2_EOF
.terragrunt-source-manifest*
HELMIGNORE2_EOF
}

dependency "eks_cluster" {
  config_path  = "../eks-cluster"
  mock_outputs = include.root.locals.common_vars.mock_outputs.eks_cluster
}

dependency "oidc_provider" {
  config_path  = "../oidc-provider"
  mock_outputs = include.root.locals.common_vars.mock_outputs.eks_cluster
}

locals {
  aws_account_id = include.root.locals.aws_account_id
  aws_region     = include.root.locals.aws_region
  aws_endpoint   = include.root.locals.environment_vars.aws_endpoint
  ecr_collection = include.root.locals.environment_vars.ecr_collection
  ecr_registry = "${local.aws_account_id}.dkr.ecr.${local.aws_region}.${local.aws_endpoint}/${local.ecr_collection}"
}

inputs = {

  cluster_name                       = dependency.eks_cluster.outputs.cluster_name
  cluster_endpoint                   = dependency.eks_cluster.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks_cluster.outputs.cluster_certificate_authority_data

  helm_debug_enable = false

  iam_role_permissions_boundary_arn = "arn:aws-iso:iam::${local.aws_account_id}:policy/PB-${include.root.locals.environment_vars.environment}-WLDEVELOPER-C2E-TS"
  oidc_provider_arn                 = dependency.oidc_provider.outputs.arn

  enable_aws_load_balancer_controller       = true
  aws_loadbalancer_controller_chart_version = "1.8.1"
  aws_loadbalancer_controller_image = {
    repository  = "${local.aws_account_id}.dkr.ecr.${local.aws_region}.${local.aws_endpoint}/${local.ecr_collection}/aws-load-balancer-controller"
    tag         = "v2.8.1"
    pull_policy = "Always"
  }

  enable_aws_ebs_csi_driver    = true
  ebs_csi_driver_chart_version = "2.33.0"
  ebs_csi_driver_image = {
    pull_policy             = "Always"
    root_repository         = "${local.aws_account_id}.dkr.ecr.${local.aws_region}.${local.aws_endpoint}/${local.ecr_collection}"
    driver_tag              = "v1.29.1"
    provisioner_tag         = "v5.0.1-eks-1-29-17"
    attacher_tag            = "v4.6.1-eks-1-29-17"
    snapshotter_tag         = "v8.0.1-eks-1-29-17"
    livenessprobe_tag       = "v2.13.0-eks-1-29-17"
    resizer_tag             = "v1.11.1-eks-1-29-17"
    nodeDriverRegistrar_tag = "v2.11.0-eks-1-29-17"
    volumemodifier_tag      = "v0.3.0"
  }

  enable_sequoia_aws_imds_proxy        = true
  sequoia_aws_imds_proxy_chart_version = "1.1.0"
  sequoia_aws_imds_proxy_image = {
    repository  = "public.ecr.aws/sequoia/combine/imds-proxy"
    tag         = "v1.1.0"
    pull_policy = "Always"
  }
  sequoia_aws_imds_proxy_target_region = local.aws_region

  ebs_csi_driver_node_role_name = "PROJECT_aws-ebs-csi-driver-node-${include.root.locals.environment_vars.environment}"
  ebs_csi_driver_node_service_account_name = "ebs-csi-node-sa-${include.root.locals.environment_vars.environment}"
  ebs_csi_driver_controller_role_name = "PROJECT_aws-ebs-csi-driver-controller-${include.root.locals.environment_vars.environment}"
  ebs_csi_driver_controller_service_account_name = "ebs-csi-controller-sa-${include.root.locals.environment_vars.environment}"
}
EOF

else
    # For custom networking, create eks-auth and eks-node-group-separate-subnets like combine-ss-test

    # Create eks-node-group-separate-subnets directory
    mkdir -p "terragrunt/${ENVIRONMENT}/eks-node-group-separate-subnets"
    cat > "terragrunt/${ENVIRONMENT}/eks-node-group-separate-subnets/terragrunt.hcl" << EOF
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "\${include.root.locals.module_base_source_url}//eks-node-group-separate-subnets\${include.root.locals.module_base_version}"
}

locals {
  aws_region  = include.root.locals.aws_region
  aws_profile = include.root.locals.aws_profile
}

# This module depends on the EKS cluster being created first
dependency "eks_cluster" {
  config_path = "../eks-cluster-separate-subnets"

  mock_outputs = {
    cluster_name    = "mock-cluster"
    cluster_version = "1.30"
  }
}

inputs = {
  # Get cluster info from the EKS cluster dependency
  cluster_name    = dependency.eks_cluster.outputs.cluster_name
  cluster_version = dependency.eks_cluster.outputs.cluster_version

  # Node subnets: where EC2 nodes / primary ENIs live
  # have access to VPC endpoints for AWS services
  node_subnet_ids = [
$(echo -e "$NODE_SUBNET_LIST")
  ]

  # Node group sizing
  min_size     = 1
  max_size     = 3
  desired_size = 1

  # Instance configuration
  instance_types = ["t3.medium", "t3.large", "t3.xlarge"]

  node_group_remote_access_key = "Combine${ENVIRONMENT}"

  combine_ca_chain_b64 = base64encode(file(include.root.locals.environment_vars.aws_ca_cert_path))

  iam_role_permissions_boundary_arn = "arn:aws-iso:iam::\${include.root.locals.environment_vars.aws_account_id}:policy/PB-\${include.root.locals.environment_vars.environment}-WLDEVELOPER-C2E-TS"

  tags = {}
}
EOF

    # Create eks-auth directory
    mkdir -p "terragrunt/${ENVIRONMENT}/eks-auth"
    cat > "terragrunt/${ENVIRONMENT}/eks-auth/terragrunt.hcl" << 'EOF'
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.module_base_source_url}//eks-auth${include.root.locals.module_base_version}"
}

dependency "eks_cluster" {
  config_path  = "../eks-cluster-separate-subnets"
  mock_outputs = include.root.locals.common_vars.mock_outputs.eks_cluster
}

dependency "node_group" {
  config_path = "../eks-node-group-separate-subnets"
  mock_outputs = {
    node_group_role_arn = "arn:aws:iam::123456789012:role/mock-node-role"
  }
}

locals {
  aws_region  = include.root.locals.aws_region
  aws_profile = include.root.locals.aws_profile
}

inputs = {

  cluster_name                       = dependency.eks_cluster.outputs.cluster_name
  cluster_endpoint                   = dependency.eks_cluster.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks_cluster.outputs.cluster_certificate_authority_data

  node_group_role_arns = [dependency.node_group.outputs.node_group_role_arn]
  admin_role_arns      = ["arn:aws-iso:iam::${include.root.locals.aws_account_id}:role/Combine-${include.root.locals.environment_vars.environment}-TS-WLDEVELOPER"]
  admin_users = [
    {
      username = "developer-combine-${include.root.locals.environment_vars.environment}"
      arn      = "arn:aws-iso:iam::${include.root.locals.aws_account_id}:user/developer-combine-${include.root.locals.environment_vars.environment}"
    }
  ]
  cluster_certificate_authority_data = dependency.eks_cluster.outputs.cluster_certificate_authority_data
  cluster_endpoint                   = dependency.eks_cluster.outputs.cluster_endpoint
  cluster_name                       = dependency.eks_cluster.outputs.cluster_name
}
EOF
fi

    print_success "Terragrunt directory structure created successfully"
    print_status "Created structure:"
    find "terragrunt/${ENVIRONMENT}" -type f -name "*.hcl" | sort
else
    print_status "Using existing terragrunt configuration"
fi

# Step 5: Check EC2 Key Pair for node access (if creating new config)
if [[ "$SKIP_CREATION" = false ]]; then
    print_status "Checking/creating EC2 Key Pair for EKS node access..."

    KEY_PAIR_NAME="Combine${ENVIRONMENT}"
    print_status "Key pair name: $KEY_PAIR_NAME"

    if aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" --region "$AWS_REGION" &>/dev/null; then
        print_success "EC2 Key Pair '$KEY_PAIR_NAME' already exists"
    else
        print_status "Creating EC2 Key Pair: $KEY_PAIR_NAME"

        # Create the key pair with RSA type
        aws ec2 create-key-pair \
            --key-name "$KEY_PAIR_NAME" \
            --key-type rsa \
            --key-format pem \
            --region "$AWS_REGION" \
            --query 'KeyMaterial' \
            --output text > "${KEY_PAIR_NAME}.pem"

        if [[ $? -eq 0 ]]; then
            # Set proper permissions on the private key file
            chmod 400 "${KEY_PAIR_NAME}.pem"

            # Add to .gitignore to prevent accidental commit
            if [[ ! -f .gitignore ]] || ! grep -q "*.pem" .gitignore; then
                echo "*.pem" >> .gitignore
                print_status "Added *.pem to .gitignore"
            fi

            print_success "Created EC2 Key Pair: $KEY_PAIR_NAME"
            print_status "Private key saved to: $(pwd)/${KEY_PAIR_NAME}.pem"
            print_warning "IMPORTANT: Keep this private key file secure - it provides SSH access to your EKS nodes"
        else
            print_error "Failed to create EC2 Key Pair: $KEY_PAIR_NAME"
            exit 1
        fi
    fi
else
    print_status "Skipping key pair check (using existing configuration)"
fi

# Step 6: Deploy infrastructure with Terragrunt
print_status "Deploying EKS cluster infrastructure..."

if [[ "$SEPARATE_SUBNETS" = true ]]; then
    # For custom networking: deploy cluster first, then node group
    print_status "Deploying EKS cluster (step 1 of 2)..."
    cd "$TERRAGRUNT_DIR"

    if ! terragrunt apply; then
        print_error "EKS cluster deployment failed"
        exit 1
    fi

    print_success "EKS cluster deployment completed"

    # Step 6.1: Configure ENI for custom networking
    print_status "Configuring VPC CNI for custom networking..."

    # Get cluster information
    ACTUAL_CLUSTER_NAME=$(terragrunt output -raw cluster_name 2>/dev/null || echo "combine-${ENVIRONMENT}-eks")
    print_status "Cluster name: $ACTUAL_CLUSTER_NAME"

    # =========Need access entry before kubectl=================
    print_status "Creating EKS access entry for IAM role..."
    ROLE_ARN="arn:aws-iso:iam::${AWS_ACCOUNT_ID}:role/Combine-${ENVIRONMENT}-TS-WLDEVELOPER"
    aws eks create-access-entry \
        --cluster-name "$ACTUAL_CLUSTER_NAME" \
        --principal-arn "$ROLE_ARN" \
        --type STANDARD \
        --region "$AWS_REGION"

    POLICY_ARN="arn:aws-iso:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    aws eks associate-access-policy \
        --cluster-name "$ACTUAL_CLUSTER_NAME" \
        --principal-arn "$ROLE_ARN" \
        --policy-arn "$POLICY_ARN" \
        --access-scope type=cluster \
        --region "$AWS_REGION"
    #==========================================================

    # Configure kubectl
    print_status "Configuring kubectl..."
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$ACTUAL_CLUSTER_NAME"

    # Enable VPC CNI custom networking
    print_status "Enabling VPC CNI custom network configuration..."
    kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true

    # Get cluster security group ID
    print_status "Retrieving cluster security group ID..."
    CLUSTER_SECURITY_GROUP_ID=$(aws eks describe-cluster \
        --name "$ACTUAL_CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" \
        --output text)

    if [[ -z "$CLUSTER_SECURITY_GROUP_ID" ]]; then
        print_error "Failed to retrieve cluster security group ID"
        exit 1
    fi

    print_success "Cluster security group ID: $CLUSTER_SECURITY_GROUP_ID"

    # Create ENIConfig resources for each availability zone with pod subnets
    print_status "Creating ENIConfig resources..."

    # Function to convert ISO region to commercial region for kubectl
    convert_iso_to_commercial_az() {
        local iso_az="$1"
        # Convert us-iso-east-1a to us-east-1a, us-isob-east-1a to us-east-1a, etc.
        echo "$iso_az" | sed -E 's/us-iso[ab]?-/us-/'
    }

    # Create ENIConfigs based on discovered pod subnets
    for pod_subnet_id in "${POD_SUBNET_IDS[@]}"; do
        # Get the availability zone for this subnet
        AZ=$(echo "$SUBNET_DATA" | jq -r ".[] | select(.SubnetId == \"$pod_subnet_id\") | .AZ")
        SUBNET_NAME=$(echo "$SUBNET_DATA" | jq -r ".[] | select(.SubnetId == \"$pod_subnet_id\") | .Name")

        if [[ -n "$AZ" ]]; then
            # Convert ISO AZ to commercial AZ for kubectl compatibility
            COMMERCIAL_AZ=$(convert_iso_to_commercial_az "$AZ")

            print_status "Creating ENIConfig for AZ: $AZ -> $COMMERCIAL_AZ (subnet: $pod_subnet_id - $SUBNET_NAME)"

            kubectl apply -f - <<EOF
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata:
  name: $COMMERCIAL_AZ
spec:
  subnet: $pod_subnet_id
  securityGroups:
    - $CLUSTER_SECURITY_GROUP_ID
EOF

            if [[ $? -eq 0 ]]; then
                print_success "Created ENIConfig for $COMMERCIAL_AZ"
            else
                print_error "Failed to create ENIConfig for $COMMERCIAL_AZ"
                exit 1
            fi
        else
            print_warning "Could not determine AZ for subnet $pod_subnet_id"
        fi
    done

    # Configure ENIConfig label
    print_status "Configuring ENI_CONFIG_LABEL_DEF..."
    kubectl set env daemonset aws-node -n kube-system ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone

    # Verify ENIConfigs were created
    print_status "Verifying ENIConfig resources..."
    kubectl get eniconfigs

    print_success "VPC CNI custom networking configuration completed"

    # Now deploy the node group
    print_status "Deploying EKS node group (step 2 of 2)..."
    cd "../eks-node-group-separate-subnets"

    if ! terragrunt apply; then
        print_error "EKS node group deployment failed"
        exit 1
    fi

    print_success "EKS node group deployment completed"

    # Return to the cluster directory for subsequent operations
    cd "../eks-cluster-separate-subnets"
else
    # For regular EKS: deploy everything together
    cd "$TERRAGRUNT_DIR"

    if ! terragrunt apply; then
        print_error "Terragrunt apply failed"
        exit 1
    fi

    ACTUAL_CLUSTER_NAME=$(terragrunt output -raw cluster_name 2>/dev/null || echo "combine-${ENVIRONMENT}-eks")

    # Configure kubectl
    print_status "Configuring kubectl..."
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$ACTUAL_CLUSTER_NAME"
fi

print_success "Infrastructure deployment completed"

# Step 7: Setup IAM Access Entry for cluster access (only for regular clusters)
# Separate subnets deployment handles this earlier in the script
if [[ "$SEPARATE_SUBNETS" = false ]]; then
    print_status "Setting up IAM Access Entry for cluster access..."

    # Construct the expected IAM role ARN
    EXPECTED_ROLE_ARN="arn:aws-iso:iam::${AWS_ACCOUNT_ID}:role/Combine-${ENVIRONMENT}-TS-WLDEVELOPER"

    echo
    print_status "Proposed IAM Role ARN: $EXPECTED_ROLE_ARN"
    echo
    read -p "Is this IAM role ARN correct? (y/N): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ROLE_ARN="$EXPECTED_ROLE_ARN"
    else
        echo
        print_status "Please provide the correct environment name to replace '$ENVIRONMENT' in the ARN:"
        print_status "Base format: arn:aws-iso:iam::${AWS_ACCOUNT_ID}:role/Combine-<ENVIRONMENT>-TS-WLDEVELOPER"
        echo
        read -p "Enter the correct environment name: " CORRECT_ENV

        if [[ -z "$CORRECT_ENV" ]]; then
            print_error "No environment name provided. Skipping IAM access entry setup."
        else
            ROLE_ARN="arn:aws-iso:iam::${AWS_ACCOUNT_ID}:role/Combine-${CORRECT_ENV}-TS-WLDEVELOPER"
            print_status "Using IAM Role ARN: $ROLE_ARN"
        fi
    fi

    if [[ -n "$ROLE_ARN" ]]; then
        print_status "Setting up IAM Access Entry for cluster..."

        # Get the actual cluster name from terragrunt outputs
        ACTUAL_CLUSTER_NAME=$(terragrunt output -raw cluster_name 2>/dev/null || echo "combine-${ENVIRONMENT}-eks")

        POLICY_ARN="arn:aws-iso:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

        # Check if access entry already exists
        if aws eks describe-access-entry \
            --cluster-name "$ACTUAL_CLUSTER_NAME" \
            --principal-arn "$ROLE_ARN" \
            --region "$AWS_REGION" &>/dev/null; then

            print_status "IAM Access Entry already exists for: $ROLE_ARN"
            ENTRY_EXISTS=true
        else
            print_status "Creating new IAM Access Entry for: $ROLE_ARN"

            # Create the access entry
            if aws eks create-access-entry \
                --cluster-name "$ACTUAL_CLUSTER_NAME" \
                --principal-arn "$ROLE_ARN" \
                --type STANDARD \
                --region "$AWS_REGION" &>/dev/null; then

                print_success "Created IAM Access Entry"
                ENTRY_EXISTS=true
            else
                print_error "Failed to create IAM Access Entry"
                print_error "Please create the access entry manually in the AWS Console:"
                print_error "1. Go to EKS Console → $ACTUAL_CLUSTER_NAME → Access tab"
                print_error "2. Create access entry for: $ROLE_ARN"
                print_error "3. Associate policy: AmazonEKSClusterAdminPolicy"
                ENTRY_EXISTS=false
            fi
        fi

        # Ensure policy is associated if entry exists
        if [[ "$ENTRY_EXISTS" = true ]]; then
            print_status "Ensuring AmazonEKSClusterAdminPolicy is associated..."

            # Check if policy is already associated
            if aws eks list-associated-access-policies \
                --cluster-name "$ACTUAL_CLUSTER_NAME" \
                --principal-arn "$ROLE_ARN" \
                --region "$AWS_REGION" \
                --query "associatedAccessPolicies[?policyArn=='$POLICY_ARN']" \
                --output text 2>/dev/null | grep -q "$POLICY_ARN"; then

                print_success "AmazonEKSClusterAdminPolicy already associated"
                print_success "IAM Access Entry setup completed"
            else
                # Associate the policy
                # NOTE: command currently fails because principal-arn is not being rewritten
                if aws eks associate-access-policy \
                    --cluster-name "$ACTUAL_CLUSTER_NAME" \
                    --principal-arn "$ROLE_ARN" \
                    --policy-arn "$POLICY_ARN" \
                    --access-scope type=cluster \
                    --region "$AWS_REGION" &>/dev/null; then

                    print_success "Successfully associated AmazonEKSClusterAdminPolicy"
                    print_success "IAM Access Entry setup completed"
                else
                    print_warning "Failed to associate AmazonEKSClusterAdminPolicy"
                    print_warning "You may need to associate the policy manually in the AWS Console"
                fi
            fi
        fi
    fi
else
    print_status "Skipping IAM Access Entry setup for separate subnets deployment (handled earlier)"
fi

# Step 8: Deploy eks-auth module
if [[ "$SKIP_EKS_AUTH" = false ]]; then
    print_status "Deploying eks-auth module..."

    # Set eks-auth directory path (use absolute path)
    EKS_AUTH_DIR="${ORIGINAL_DIR}/terragrunt/${ENVIRONMENT}/eks-auth"

    if [[ -d "$EKS_AUTH_DIR" ]]; then
        cd "$EKS_AUTH_DIR"

        if terragrunt apply; then
            print_success "eks-auth module deployment completed"
        else
            print_warning "eks-auth module deployment failed"
            print_status "You can manually deploy later with: cd $EKS_AUTH_DIR && terragrunt apply"
        fi

        if [[ "$SEPARATE_SUBNETS" = true ]]; then
            cd "../eks-cluster-separate-subnets"
        else
            cd "../eks-cluster"
        fi
    else
        print_warning "eks-auth directory not found at $EKS_AUTH_DIR"
    fi
else
    print_warning "Skipping eks-auth module deployment (--skip-auth flag used)"
fi

# Step 9: Verify deployment and summary
ACTUAL_CLUSTER_NAME=$(cd "${ORIGINAL_DIR}/${TERRAGRUNT_DIR}" && terragrunt output -raw cluster_name 2>/dev/null || echo "combine-${ENVIRONMENT}-eks")
CLUSTER_ENDPOINT=$(cd "${ORIGINAL_DIR}/${TERRAGRUNT_DIR}" && terragrunt output -raw cluster_endpoint 2>/dev/null || echo "")

if [[ "$SEPARATE_SUBNETS" = true ]]; then
    print_status "Verifying custom networking..."
    ENICONFIG_NAMES=$(kubectl get eniconfigs --no-headers 2>/dev/null | awk '{print $1}')
    if [[ -n "$ENICONFIG_NAMES" ]]; then
        print_status "ENIConfigs created:"
        echo "$ENICONFIG_NAMES" | while read -r name; do
            printf "  %s\n" "$name"
        done
    else
        print_status "ENIConfigs created: none"
    fi
fi

print_success "EKS Deployment Complete!"
print_status "Cluster: $ACTUAL_CLUSTER_NAME"
print_status "Region: $AWS_REGION"
print_status "VPC: $VPC_ID"

if [[ "$SEPARATE_SUBNETS" = true ]]; then
    print_status "Node subnets:"
    for subnet_id in "${NODE_SUBNET_IDS[@]}"; do
        CIDR=$(echo "$SUBNET_DATA" | jq -r ".[] | select(.SubnetId == \"$subnet_id\") | .CIDR")
        printf "  %s (%s)\n" "$subnet_id" "$CIDR"
    done
    print_status "Pod subnets:"
    for subnet_id in "${POD_SUBNET_IDS[@]}"; do
        CIDR=$(echo "$SUBNET_DATA" | jq -r ".[] | select(.SubnetId == \"$subnet_id\") | .CIDR")
        printf "  %s (%s)\n" "$subnet_id" "$CIDR"
    done
else
    print_status "Subnets:"
    for subnet_id in "${NODE_SUBNET_IDS[@]}"; do
        CIDR=$(echo "$SUBNET_DATA" | jq -r ".[] | select(.SubnetId == \"$subnet_id\") | .CIDR")
        printf "  %s (%s)\n" "$subnet_id" "$CIDR"
    done
fi

# Return to original directory
cd "$ORIGINAL_DIR"

print_success "Deployment script completed successfully!"