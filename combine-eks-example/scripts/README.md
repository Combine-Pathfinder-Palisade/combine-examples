# Combine EKS Example Scripts Directory

This directory contains automation scripts for the combine-terraform project.

## install-dependencies.sh

System dependency installation script for Amazon Linux environments with CloudFormation validation.

**Prerequisites Check:**
- Prompts for your shard name
- Validates CloudFormation stack `Combine-<shard-name>-Policy`
- Checks required role hierarchy parameters:
  - `EnableRoleHierarchyC2E`
  - `EnableRoleHierarchyC2EPermissionBoundary`
  - `EnableRoleHierarchyC2ESelfService`
- Exits with error if any parameters are disabled

**What it installs:**
- Git
- Helm 3
- kubectl
- kubectx/kubens
- Terraform (via HashiCorp repository)
- Terragrunt (latest release)

**Usage:**
```bash
./scripts/install-dependencies.sh
```

**Requirements:**
- Amazon Linux with yum package manager
- Sudo privileges
- AWS CLI configured with appropriate credentials
- `jq` installed (for JSON parsing)
- Valid CloudFormation stack with required role hierarchy parameters enabled

## configure-eks-custom-networking.sh

Automates the configuration of EKS custom networking for clusters with separate pod and node subnets. This script implements all steps from the manual custom networking configuration process.

**What it does:**
- Updates kubeconfig for cluster access
- Enables VPC CNI custom networking capability
- Retrieves cluster security group for ENIConfig configuration
- Discovers and displays all subnets associated with the cluster
- Creates ENIConfig resources for each availability zone
- Configures ENIConfig label definition for automatic pod subnet assignment
- Validates configuration and provides summary

**Key Features:**
- **ISO Region Support**: Automatically converts ISO availability zones (`us-iso-east-1a`) to commercial format (`us-east-1a`) for ENIConfig resources
- **Multiple Subnet Detection**: Warns when multiple subnets are detected in the same AZ
- **Subnet Information**: Displays subnet name, ID, CIDR block, and availability zone
- **Error Handling**: Validates cluster existence, subnet availability, and configuration prerequisites

**Usage:**
```bash
./scripts/configure-eks-custom-networking.sh <cluster-name>
```

**Prerequisites:**
- AWS CLI configured with appropriate credentials
- `kubectl` installed and in PATH
- Cluster must already exist with subnets configured
- Appropriate IAM permissions for EKS and EC2 operations

**Important Notes:**
- Script creates ONE ENIConfig per availability zone using the first subnet found
- If multiple subnets exist in the same AZ, only the first is used (warning displayed)
- To use multiple subnets per AZ, manual ENIConfig creation and node annotation required
- All nodes in an AZ will share the same pod subnet unless manually configured otherwise

**Troubleshooting:**
- **Multiple Subnets per AZ**: Review warning message and AWS documentation for manual configuration steps
- **ISO Region Issues**: Verify availability zone format if ENIConfig creation fails
- **kubectl Access**: Ensure kubeconfig is properly configured and cluster is accessible

## create-and-deploy-eks.sh
***Note:** provisions cluster using version **20.17.2** of the `terraform-aws-eks` module*

### Usage

```bash
./scripts/create-and-deploy-eks.sh -e ENVIRONMENT -v VPC_ID [OPTIONS]
```

### Required Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-e, --environment` | Environment name | `combine-ss-test`, `combine-jposada-eks` |
| `-v, --vpc-id` | VPC ID to deploy into | `vpc-1234567890abcdef0` |

### Optional Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-n, --separate-nets` | Enable custom networking with separate pod/node subnets | `false` |
| `-r, --region` | AWS region | `us-iso-east-1` |
| `-a, --skip-auth` | Skip eks-auth module deployment | `false` |
| `-h, --help` | Show help message | - |

### Examples
```bash
# Standard EKS Cluster
./scripts/create-and-deploy-eks.sh -e my-cluster -v vpc-1234567890abcdef0

# EKS with Custom Networking
./scripts/create-and-deploy-eks.sh -e my-cluster -v vpc-1234567890abcdef0 -n

# Custom Region
./scripts/create-and-deploy-eks.sh -e my-cluster -v vpc-1234567890abcdef0 -n -r us-east-1

# Skip eks-auth setup
./scripts/create-and-deploy-eks.sh -e my-cluster -v vpc-1234567890abcdef0 -a
```

### Features & Deployment Flow

| Stage | Actions | Custom Networking Mode |
|-------|---------|------------------------|
| **Prerequisites** | Validates AWS credentials, directory structure | Same for both modes |
| **Subnet Discovery** | Scans VPC for available subnets (excludes RESTRICTED) | Separates by pattern: `*-AZ-*1` (nodes), `*-AZ-*2` (pods) |
| **Infrastructure** | Creates S3 state bucket, EC2 key pairs, and terragrunt configs | Same infrastructure components |
| **Cluster Deploy** | Runs `terragrunt apply` to create EKS cluster | For custom networking: deploys cluster first, then node group separately |
| **Custom Networking** | Standard VPC CNI configuration | Configures VPC CNI, creates ENIConfigs with ISO→commercial region conversion, validates configuration |
| **IAM Setup** | Creates access entries with `AmazonEKSClusterAdminPolicy` | For custom networking: handled early in deployment. For standard: handled in dedicated step |
| **eks-auth Deploy** | Automatically deploys eks-auth module after cluster creation | Same for both modes |
| **Verification** | Displays cluster summary with basic information | Shows ENIConfig names and detailed subnet information |

### Generated Structure

#### Standard EKS (`-e my-env -v vpc-1234567890abcdef0`)
```
terragrunt/my-env/
├── env.hcl
├── eks-cluster/
│   └── terragrunt.hcl
├── eks-auth/
│   └── terragrunt.hcl
├── oidc-provider/
│   └── terragrunt.hcl
└── plugins/
    └── terragrunt.hcl
```

#### Custom Networking EKS (`-e my-env -v vpc-1234567890abcdef0 -n`)
```
terragrunt/my-env/
├── env.hcl
├── eks-cluster-separate-subnets/
│   └── terragrunt.hcl
├── eks-node-group-separate-subnets/
│   └── terragrunt.hcl
└── eks-auth/
    └── terragrunt.hcl
```

### Under the Hood

#### ISO Region Support
- Required for kubectl operations in Combine where AWS APIs use are rewritten but Kubernetes resources need commercial region names
- Automatically converts ISO availability zones (`us-iso-east-1a`) to commercial format (`us-east-1a`) for ENIConfig resources
- Handles both `us-iso` and `us-isob` region formats

#### Subnet Detection
- Automatically discovers and categorizes subnets in the target VPC
- Excludes subnets with names starting with "RESTRICTED"
- For custom networking:
    - separates subnets by naming pattern
        - (`*-AZ-*1` for nodes, `*-AZ-*2` for pods)
    - End up with 1 node subnet and 1 pod subnet per region
- Provides fallback allocation if naming pattern is not detected

### Existing Configuration Handling

When existing terragrunt configuration is detected, the script offers three options:

1. **Use Existing**: Skip file creation, proceed with deployment
2. **Recreate**: Overwrite existing configuration files
3. **Exit**: Exit gracefully with manual deployment instructions

### Prerequisites

- AWS CLI configured with appropriate credentials
- `terragrunt` installed and in PATH
- `kubectl` installed (for custom networking verification and ENIConfig management)
- `jq` installed (for JSON parsing)
- Appropriate IAM permissions for EKS, EC2, S3, and IAM operations

### Troubleshooting
- **Subnet Pattern Detection**: If custom networking fails to detect proper subnet patterns, the script will use fallback allocation and display available subnets for manual verification
- **ISO Region Conversion**: ENIConfig creation may fail if availability zones cannot be properly converted from ISO to commercial format
- **IAM Access Entry**: Script provides manual steps if automated IAM access entry creation fails
- **eks-auth Dependencies**: Must have IAM access entry with `AmazonEKSClusterAdminPolicy` set up prior. Use `--skip-auth` flag if eks-auth deployment fails and deploy manually later
