#!/bin/bash

# Script to configure EKS Custom Networking for separate pod and node subnets
# Usage: ./configure-eks-custom-networking.sh <cluster-name>

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Print functions
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

print_header() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_step() {
    echo -e "\n${MAGENTA}▶${NC} $1${NC}"
}

# Check if cluster name is provided
if [ -z "$1" ]; then
    print_error "Cluster name is required"
    echo "Usage: $0 <cluster-name>"
    exit 1
fi

CLUSTER_NAME="$1"

# Function to convert ISO AZs to commercial AZs
convert_iso_to_commercial_az() {
    local iso_az="$1"
    # Convert us-iso-east-1a to us-east-1a, us-isob-east-1a to us-east-1a, etc.
    echo "$iso_az" | sed -E 's/us-iso[ab]?-/us-/'
}

print_header "Configuring Custom Networking for EKS Cluster: $CLUSTER_NAME"

# Step 2.1: Get Cluster Credentials
print_step "Step 2.1: Updating kubeconfig..."
REGION=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.arn" --output text | cut -d: -f4)
print_status "Detected region: ${CYAN}$REGION"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" > /dev/null 2>&1
print_success "Kubeconfig updated"

# Step 2.2: Enable Custom Network Configuration
print_step "Step 2.2: Enabling VPC CNI custom networking..."
kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true > /dev/null 2>&1
print_success "Custom networking enabled"

# Step 2.3: Get Cluster Security Group ID
print_step "Step 2.3: Retrieving cluster security group..."
CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text --region "$REGION")
print_status "Cluster Security Group ID: ${CYAN}$CLUSTER_SG${NC}"

# Step 2.4: Get all subnets associated with the cluster
print_step "Step 2.4: Retrieving cluster subnets..."
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.resourcesVpcConfig.subnetIds[]" --output text --region "$REGION")

if [ -z "$SUBNET_IDS" ]; then
    print_error "No subnets found for cluster $CLUSTER_NAME"
    exit 1
fi

SUBNET_COUNT=$(echo "$SUBNET_IDS" | wc -w | xargs)
print_success "Found ${GREEN}$SUBNET_COUNT${NC} subnets"
echo ""

for subnet_id in $SUBNET_IDS; do
    SUBNET_INFO=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" --region "$REGION" --query "Subnets[0].[Tags[?Key=='Name'].Value | [0], SubnetId, CidrBlock, AvailabilityZone]" --output text)
    SUBNET_NAME=$(echo "$SUBNET_INFO" | awk '{print $1}')
    SUBNET_ID=$(echo "$SUBNET_INFO" | awk '{print $2}')
    SUBNET_CIDR=$(echo "$SUBNET_INFO" | awk '{print $3}')
    SUBNET_AZ=$(echo "$SUBNET_INFO" | awk '{print $4}')
    
    if [ "$SUBNET_NAME" = "None" ] || [ -z "$SUBNET_NAME" ]; then
        SUBNET_NAME="(unnamed)"
    fi
    
    echo -e "  ${NC}•${NC} ${NC}$SUBNET_NAME${NC}"
    echo -e "    ${NC}├─${NC} ID: ${GREEN}$SUBNET_ID${NC}"
    echo -e "    ${NC}├─${NC} CIDR: ${BLUE}$SUBNET_CIDR${NC}"
    echo -e "    ${NC}└─${NC} AZ: ${MAGENTA}$SUBNET_AZ${NC}"
    echo ""
done

# Create ENIConfig for each subnet's availability zone
print_step "Step 2.5: Creating ENIConfig resources..."

declare -A az_subnet_map
declare -A az_subnet_count

# Count subnets per AZ and map first subnet to each AZ
for subnet_id in $SUBNET_IDS; do
    # Get the availability zone for this subnet
    AZ=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" --query "Subnets[0].AvailabilityZone" --output text --region "$REGION")
    
    # Count subnets per AZ
    if [ -z "${az_subnet_count[$AZ]}" ]; then
        az_subnet_count[$AZ]=1
    else
        az_subnet_count[$AZ]=$((${az_subnet_count[$AZ]} + 1))
    fi
    
    # Store the first subnet found for each AZ
    if [ -z "${az_subnet_map[$AZ]}" ]; then
        az_subnet_map[$AZ]=$subnet_id
        print_status "Mapping AZ ${MAGENTA}$AZ${NC} to subnet ${CYAN}$subnet_id${NC}"
    fi
done

# Check for multiple subnets in same AZ and warn
echo ""
for AZ in "${!az_subnet_count[@]}"; do
    if [ "${az_subnet_count[$AZ]}" -gt 1 ]; then
        print_warning "Multiple subnets (${az_subnet_count[$AZ]}) detected in AZ ${YELLOW}$AZ${NC}"
        echo -e "  "
        echo -e "  ${YELLOW}•${NC} ENIConfig will be created for only ONE subnet per AZ (${CYAN}${az_subnet_map[$AZ]}${NC})"
        echo -e "  ${YELLOW}•${NC} All nodes in ${YELLOW}$AZ${NC} will use this subnet for pod networking"
        echo -e "  "
        echo -e "  ${BLUE}•${NC} ${BLUE}Note:${NC} To use multiple subnets in the same AZ, you must:"
        echo -e "     ${BLUE}◦${NC} Create separate ENIConfig resources for each subnet"
        echo -e "     ${BLUE}◦${NC} Manually annotate nodes with specific ENIConfig names"
        echo ""
    fi
done

echo ""
# Create ENIConfig for each unique availability zone
for AZ in "${!az_subnet_map[@]}"; do
    SUBNET_ID="${az_subnet_map[$AZ]}"
    
    # Convert ISO AZ to commercial AZ for ENIConfig name
    COMMERCIAL_AZ=$(convert_iso_to_commercial_az "$AZ")
    
    print_status "Creating ENIConfig for ${MAGENTA}$AZ${NC} (commercial: ${CYAN}$COMMERCIAL_AZ${NC}, subnet: ${CYAN}$SUBNET_ID${NC})..."
    
    cat <<EOF | kubectl apply -f - > /dev/null 2>&1
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata:
  name: $COMMERCIAL_AZ
spec:
  subnet: $SUBNET_ID
  securityGroups:
    - $CLUSTER_SG
EOF
    
    print_success "ENIConfig created for ${GREEN}$COMMERCIAL_AZ${NC}"
done

# Step 2.6: Configure ENIConfig Label
print_step "Step 2.6: Configuring ENIConfig label definition..."
kubectl set env daemonset aws-node -n kube-system ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone > /dev/null 2>&1
print_success "ENIConfig label configured"

echo ""
print_header "✓ Custom Networking Configuration Complete!"

echo -e "${CYAN}Summary:${NC}"
echo -e "  ${NC}•${NC} Cluster: ${GREEN}$CLUSTER_NAME${NC}"
echo -e "  ${NC}•${NC} Region: ${GREEN}$REGION${NC}"
echo -e "  ${NC}•${NC} Security Group: ${GREEN}$CLUSTER_SG${NC}"
echo -e "  ${NC}•${NC} ENIConfigs created for ${GREEN}${#az_subnet_map[@]}${NC} availability zones"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo -e "  ${NC}1.${NC} Deploy the worker node group"
echo -e "  ${NC}2.${NC} Verify pods are being assigned IPs from the correct subnets"
echo ""
