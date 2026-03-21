#!/bin/bash
##############################################################################
# ssh_imds_bootstrap.sh
#
# Launches two EC2 instances:
#   1. BASTION  — internet-facing (public IP, SSH open), used as the SSM
#                 entry point and SSH jump host. Key pair is transferred here.
#   2. IMDS BOX — target instance in the specified VPC/subnet, private only,
#                 SSH accessible from the bastion using the transferred key.
#
# The IMDS proxy installer is staged on the IMDS box via S3 + user data,
# ready to run after you SSH in.
#
# Usage:
#   bash ssh_imds_bootstrap.sh [OPTIONS]
#
# Options:
#   --region        AWS region                        (default: us-east-1)
#   --target-vpc    VPC ID for the IMDS box           (required)
#   --target-subnet Subnet ID for the IMDS box        (required)
#   --bastion-vpc   VPC ID for the bastion            (default: default VPC)
#   --bastion-subnet Subnet ID for bastion            (default: auto-select public)
#   --your-ip       Your public IP for SSH allow rule (default: auto-detect)
#   --key-name      Existing key pair name to reuse   (default: creates new)
#   --instance-type EC2 instance type                 (default: t3.micro)
#
# Example:
#   bash ssh_imds_bootstrap.sh \
#     --target-vpc vpc-0cacbefb146fc36a1 \
#     --target-subnet subnet-0a789237a1a17d8f8
##############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Defaults
# =============================================================================
REGION="us-east-1"
TARGET_VPC=""
TARGET_SUBNET=""
BASTION_VPC=""
BASTION_SUBNET=""
YOUR_IP=""
KEY_NAME=""
INSTANCE_TYPE="t3.micro"
TAG_PREFIX="imds-proxy"
STATE_FILE="${SCRIPT_DIR}/ssh-imds-deploy-state.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
ok()    { echo -e "${GREEN}  ✓${NC} $1"; }
header(){ echo -e "\n${BOLD}── $1 ──${NC}"; }

# =============================================================================
# Argument parsing
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)         REGION="$2";         shift 2 ;;
        --target-vpc)     TARGET_VPC="$2";     shift 2 ;;
        --target-subnet)  TARGET_SUBNET="$2";  shift 2 ;;
        --bastion-vpc)    BASTION_VPC="$2";    shift 2 ;;
        --bastion-subnet) BASTION_SUBNET="$2"; shift 2 ;;
        --your-ip)        YOUR_IP="$2";        shift 2 ;;
        --key-name)       KEY_NAME="$2";       shift 2 ;;
        --instance-type)  INSTANCE_TYPE="$2";  shift 2 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

[[ -z "${TARGET_VPC}"    ]] && error "--target-vpc is required."
[[ -z "${TARGET_SUBNET}" ]] && error "--target-subnet is required."

[[ -f "${SCRIPT_DIR}/imds-proxy-install-aws.sh" ]] \
    || error "Required file not found: ${SCRIPT_DIR}/imds-proxy-install-aws.sh"

command -v aws >/dev/null 2>&1 || error "AWS CLI not found."
aws sts get-caller-identity --region "${REGION}" >/dev/null 2>&1 \
    || error "AWS CLI cannot authenticate to ${REGION}."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_BUCKET="${TAG_PREFIX}-scripts-${ACCOUNT_ID}"

# =============================================================================
# Auto-detect your public IP
# =============================================================================
header "Resolving caller IP"
if [[ -z "${YOUR_IP}" ]]; then
    YOUR_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com || \
              curl -s --max-time 5 https://api.ipify.org || echo "")
    [[ -z "${YOUR_IP}" ]] && error "Could not detect your public IP. Pass --your-ip manually."
fi
YOUR_IP_CIDR="${YOUR_IP}/32"
ok "Your IP: ${YOUR_IP_CIDR}"

# =============================================================================
# Resolve bastion VPC / subnet
# =============================================================================
header "Resolving bastion placement"
if [[ -z "${BASTION_VPC}" ]]; then
    BASTION_VPC=$(aws ec2 describe-vpcs \
        --region "${REGION}" \
        --filters "Name=isDefault,Values=true" \
        --query "Vpcs[0].VpcId" \
        --output text 2>/dev/null || echo "")
    [[ -z "${BASTION_VPC}" || "${BASTION_VPC}" == "None" ]] \
        && error "No default VPC found. Specify --bastion-vpc explicitly."
    ok "Using default VPC for bastion: ${BASTION_VPC}"
fi

if [[ -z "${BASTION_SUBNET}" ]]; then
    BASTION_SUBNET=$(aws ec2 describe-subnets \
        --region "${REGION}" \
        --filters "Name=vpc-id,Values=${BASTION_VPC}" \
                  "Name=mapPublicIpOnLaunch,Values=true" \
        --query "Subnets | sort_by(@, &AvailableIpAddressCount) | [-1].SubnetId" \
        --output text 2>/dev/null || echo "")
    [[ -z "${BASTION_SUBNET}" || "${BASTION_SUBNET}" == "None" ]] \
        && error "No public subnet found in ${BASTION_VPC}. Specify --bastion-subnet explicitly."
    ok "Using bastion subnet: ${BASTION_SUBNET}"
fi

# Confirm target subnet exists in target VPC
TARGET_SUBNET_CHECK=$(aws ec2 describe-subnets \
    --region "${REGION}" \
    --subnet-ids "${TARGET_SUBNET}" \
    --query "Subnets[0].VpcId" \
    --output text 2>/dev/null || echo "")
[[ "${TARGET_SUBNET_CHECK}" != "${TARGET_VPC}" ]] \
    && error "Subnet ${TARGET_SUBNET} does not belong to VPC ${TARGET_VPC}."
ok "Target subnet ${TARGET_SUBNET} confirmed in ${TARGET_VPC}"

# =============================================================================
# Resolve latest Amazon Linux 2 AMI
# =============================================================================
header "Resolving AMI"
AMI_ID=$(aws ec2 describe-images \
    --region "${REGION}" \
    --owners amazon \
    --filters \
        "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
        "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)
[[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]] && error "Could not resolve AMI ID."
ok "AMI: ${AMI_ID}"

# =============================================================================
# Key pair
# =============================================================================
header "Key pair"
KEY_DIR="${SCRIPT_DIR}/keys"
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

CREATE_KEY=false
if [[ -z "${KEY_NAME}" ]]; then
    KEY_NAME="${TAG_PREFIX}-key-$(date +%s)"
    CREATE_KEY=true
else
    # Check if key exists in AWS; if not, create it
    if ! aws ec2 describe-key-pairs \
            --region "${REGION}" \
            --key-names "${KEY_NAME}" >/dev/null 2>&1; then
        warn "Key pair '${KEY_NAME}' not found in AWS — will create it."
        CREATE_KEY=true
    else
        ok "Reusing existing key pair: ${KEY_NAME}"
    fi
fi

KEY_FILE="${KEY_DIR}/${KEY_NAME}.pem"

if [[ "${CREATE_KEY}" == "true" ]]; then
    aws ec2 create-key-pair \
        --region "${REGION}" \
        --key-name "${KEY_NAME}" \
        --query "KeyMaterial" \
        --output text > "${KEY_FILE}"
    chmod 600 "${KEY_FILE}"
    ok "Key pair created: ${KEY_NAME}"
    ok "Private key saved: ${KEY_FILE}"
else
    if [[ ! -f "${KEY_FILE}" ]]; then
        warn "Key file not found locally at ${KEY_FILE}."
        warn "You must provide it manually before SSHing."
    else
        ok "Local key file found: ${KEY_FILE}"
    fi
fi

# =============================================================================
# S3 bucket and script upload
# =============================================================================
header "S3 staging bucket"
if ! aws s3api head-bucket --bucket "${S3_BUCKET}" --region "${REGION}" 2>/dev/null; then
    if [[ "${REGION}" == "us-east-1" ]]; then
        aws s3api create-bucket \
            --bucket "${S3_BUCKET}" \
            --region "${REGION}" >/dev/null
    else
        aws s3api create-bucket \
            --bucket "${S3_BUCKET}" \
            --region "${REGION}" \
            --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    fi
    aws s3api put-public-access-block \
        --bucket "${S3_BUCKET}" \
        --region "${REGION}" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    ok "Bucket created: ${S3_BUCKET}"
else
    ok "Bucket already exists: ${S3_BUCKET}"
fi

info "Uploading installer..."
aws s3 cp "${SCRIPT_DIR}/imds-proxy-install-aws.sh" \
    "s3://${S3_BUCKET}/scripts/imds-proxy-install-aws.sh" \
    --region "${REGION}" >/dev/null
ok "Uploaded: imds-proxy-install-aws.sh"

info "Uploading private key to S3 for bastion transfer..."
aws s3 cp "${KEY_FILE}" \
    "s3://${S3_BUCKET}/keys/${KEY_NAME}.pem" \
    --region "${REGION}" >/dev/null
ok "Uploaded: ${KEY_NAME}.pem"

# =============================================================================
# IAM role (S3 read + SSM for bastion)
# =============================================================================
header "IAM roles"
ROLE_NAME="${TAG_PREFIX}-role"
PROFILE_NAME="${TAG_PREFIX}-profile"

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

S3_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::${S3_BUCKET}",
      "arn:aws:s3:::${S3_BUCKET}/*"
    ]
  }]
}
EOF
)

if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    aws iam create-role \
        --role-name "${ROLE_NAME}" \
        --assume-role-policy-document "${TRUST_POLICY}" >/dev/null
    # SSM on bastion, S3 read on both
    aws iam attach-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    aws iam put-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-name "${TAG_PREFIX}-s3-scripts" \
        --policy-document "${S3_POLICY}"
    ok "IAM role created: ${ROLE_NAME}"
else
    ok "IAM role already exists: ${ROLE_NAME}"
fi

if ! aws iam get-instance-profile \
        --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
    aws iam create-instance-profile \
        --instance-profile-name "${PROFILE_NAME}" >/dev/null
    aws iam add-role-to-instance-profile \
        --instance-profile-name "${PROFILE_NAME}" \
        --role-name "${ROLE_NAME}"
    ok "Instance profile created: ${PROFILE_NAME}"
else
    ok "Instance profile already exists: ${PROFILE_NAME}"
fi

info "Waiting 15s for IAM propagation..."
sleep 15

# =============================================================================
# Security groups
# =============================================================================
header "Security groups"

# Bastion SG — SSH from your IP only
BASTION_SG_NAME="${TAG_PREFIX}-bastion-sg"
BASTION_SG_ID=$(aws ec2 describe-security-groups \
    --region "${REGION}" \
    --filters "Name=group-name,Values=${BASTION_SG_NAME}" \
              "Name=vpc-id,Values=${BASTION_VPC}" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || echo "None")

if [[ "${BASTION_SG_ID}" == "None" || -z "${BASTION_SG_ID}" ]]; then
    BASTION_SG_ID=$(aws ec2 create-security-group \
        --region "${REGION}" \
        --group-name "${BASTION_SG_NAME}" \
        --description "IMDS proxy bastion - SSH from deployer IP" \
        --vpc-id "${BASTION_VPC}" \
        --query "GroupId" \
        --output text)
    aws ec2 authorize-security-group-ingress \
        --region "${REGION}" \
        --group-id "${BASTION_SG_ID}" \
        --protocol tcp --port 22 \
        --cidr "${YOUR_IP_CIDR}" >/dev/null
    ok "Bastion SG created: ${BASTION_SG_ID} (SSH from ${YOUR_IP_CIDR})"
else
    ok "Bastion SG already exists: ${BASTION_SG_ID}"
fi

# IMDS box SG — SSH from bastion SG only
IMDS_SG_NAME="${TAG_PREFIX}-imds-sg"
IMDS_SG_ID=$(aws ec2 describe-security-groups \
    --region "${REGION}" \
    --filters "Name=group-name,Values=${IMDS_SG_NAME}" \
              "Name=vpc-id,Values=${TARGET_VPC}" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || echo "None")

if [[ "${IMDS_SG_ID}" == "None" || -z "${IMDS_SG_ID}" ]]; then
    IMDS_SG_ID=$(aws ec2 create-security-group \
        --region "${REGION}" \
        --group-name "${IMDS_SG_NAME}" \
        --description "IMDS proxy test box - SSH from bastion only" \
        --vpc-id "${TARGET_VPC}" \
        --query "GroupId" \
        --output text)
    # Allow SSH from entire bastion VPC CIDR (cross-VPC SG reference not available
    # without VPC peering; use CIDR instead)
    BASTION_VPC_CIDR=$(aws ec2 describe-vpcs \
        --region "${REGION}" \
        --vpc-ids "${BASTION_VPC}" \
        --query "Vpcs[0].CidrBlock" \
        --output text)
    aws ec2 authorize-security-group-ingress \
        --region "${REGION}" \
        --group-id "${IMDS_SG_ID}" \
        --protocol tcp --port 22 \
        --cidr "${BASTION_VPC_CIDR}" >/dev/null
    ok "IMDS box SG created: ${IMDS_SG_ID} (SSH from ${BASTION_VPC_CIDR})"
else
    ok "IMDS box SG already exists: ${IMDS_SG_ID}"
fi

# =============================================================================
# User data — bastion
# Pulls the SSH key from S3 so it is ready to use for the onward hop.
# =============================================================================
BASTION_USERDATA=$(mktemp /tmp/bastion-userdata-XXXXXX.sh)
cat > "${BASTION_USERDATA}" <<USERDATA
#!/bin/bash
set -e
LOG=/var/log/bastion-bootstrap.log
exec > >(tee -a \$LOG) 2>&1
echo "=== Bastion bootstrap starting ==="

# Download key to a shared location readable by any user
mkdir -p /opt/imds-keys
aws s3 cp s3://${S3_BUCKET}/keys/${KEY_NAME}.pem \
    /opt/imds-keys/${KEY_NAME}.pem \
    --region ${REGION}
chmod 644 /opt/imds-keys/${KEY_NAME}.pem

# Symlink into ec2-user home
mkdir -p /home/ec2-user/.ssh
ln -sf /opt/imds-keys/${KEY_NAME}.pem /home/ec2-user/.ssh/${KEY_NAME}.pem
chown -h ec2-user:ec2-user /home/ec2-user/.ssh/${KEY_NAME}.pem

# Symlink into ssm-user home (created on first SSM connection;
# retry a few times to allow for SSM agent startup delay)
for i in 1 2 3 4 5; do
    if id ssm-user &>/dev/null && [[ -d /home/ssm-user ]]; then
        mkdir -p /home/ssm-user/.ssh
        ln -sf /opt/imds-keys/${KEY_NAME}.pem /home/ssm-user/.ssh/${KEY_NAME}.pem
        chown -h ssm-user:ssm-user /home/ssm-user/.ssh/${KEY_NAME}.pem
        echo "ssm-user symlink created on attempt \$i"
        break
    fi
    echo "Waiting for ssm-user home dir (attempt \$i)..."
    sleep 10
done

echo "=== Bastion bootstrap complete — key ready at /opt/imds-keys/${KEY_NAME}.pem ==="
USERDATA

# =============================================================================
# User data — IMDS box
# Pulls the installer from S3 and stages it for manual execution.
# =============================================================================
IMDS_USERDATA=$(mktemp /tmp/imds-userdata-XXXXXX.sh)
cat > "${IMDS_USERDATA}" <<USERDATA
#!/bin/bash
set -e
LOG=/var/log/imds-bootstrap.log
exec > >(tee -a \$LOG) 2>&1
echo "=== IMDS box bootstrap starting ==="
command -v python3 &>/dev/null || yum install -y python3
mkdir -p /opt/imds-proxy
aws s3 cp s3://${S3_BUCKET}/scripts/imds-proxy-install-aws.sh \
    /opt/imds-proxy/imds-proxy-install-aws.sh \
    --region ${REGION}
chmod 755 /opt/imds-proxy/imds-proxy-install-aws.sh
echo "=== IMDS box bootstrap complete — installer ready at /opt/imds-proxy/imds-proxy-install-aws.sh ==="
USERDATA

# =============================================================================
# Launch bastion
# =============================================================================
header "Launching bastion instance"
BASTION_ID=$(aws ec2 run-instances \
    --region "${REGION}" \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --subnet-id "${BASTION_SUBNET}" \
    --security-group-ids "${BASTION_SG_ID}" \
    --key-name "${KEY_NAME}" \
    --iam-instance-profile "Name=${PROFILE_NAME}" \
    --associate-public-ip-address \
    --user-data "file://${BASTION_USERDATA}" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_PREFIX}-bastion}]" \
    --query "Instances[0].InstanceId" \
    --output text)
ok "Bastion launched: ${BASTION_ID}"

# =============================================================================
# Launch IMDS box
# =============================================================================
header "Launching IMDS test box"
IMDS_ID=$(aws ec2 run-instances \
    --region "${REGION}" \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --subnet-id "${TARGET_SUBNET}" \
    --security-group-ids "${IMDS_SG_ID}" \
    --key-name "${KEY_NAME}" \
    --iam-instance-profile "Name=${PROFILE_NAME}" \
    --user-data "file://${IMDS_USERDATA}" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_PREFIX}-imds-box}]" \
    --query "Instances[0].InstanceId" \
    --output text)
ok "IMDS box launched: ${IMDS_ID}"

# =============================================================================
# Wait for both instances
# =============================================================================
header "Waiting for instances to reach running state"
aws ec2 wait instance-running \
    --region "${REGION}" \
    --instance-ids "${BASTION_ID}" "${IMDS_ID}"
ok "Both instances are running"

# Resolve IPs
BASTION_PUBLIC_IP=$(aws ec2 describe-instances \
    --region "${REGION}" \
    --instance-ids "${BASTION_ID}" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

IMDS_PRIVATE_IP=$(aws ec2 describe-instances \
    --region "${REGION}" \
    --instance-ids "${IMDS_ID}" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text)

ok "Bastion public IP  : ${BASTION_PUBLIC_IP}"
ok "IMDS box private IP: ${IMDS_PRIVATE_IP}"

# =============================================================================
# Save state
# =============================================================================
cat > "${STATE_FILE}" <<EOF
REGION=${REGION}
BASTION_ID=${BASTION_ID}
IMDS_ID=${IMDS_ID}
BASTION_PUBLIC_IP=${BASTION_PUBLIC_IP}
IMDS_PRIVATE_IP=${IMDS_PRIVATE_IP}
S3_BUCKET=${S3_BUCKET}
KEY_NAME=${KEY_NAME}
KEY_FILE=${KEY_FILE}
ROLE_NAME=${ROLE_NAME}
PROFILE_NAME=${PROFILE_NAME}
BASTION_SG_ID=${BASTION_SG_ID}
IMDS_SG_ID=${IMDS_SG_ID}
TAG_PREFIX=${TAG_PREFIX}
EOF
ok "State saved: ${STATE_FILE}"

# Cleanup temp files
rm -f "${BASTION_USERDATA}" "${IMDS_USERDATA}"

# =============================================================================
# Final instructions
# =============================================================================
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} DEPLOYMENT COMPLETE${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}  Instances${NC}"
echo "  Bastion  : ${BASTION_ID}  (${BASTION_PUBLIC_IP})"
echo "  IMDS box : ${IMDS_ID}  (${IMDS_PRIVATE_IP})"
echo "  Key file : ${KEY_FILE}"
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} STEP 1 — Connect to the bastion via SSM${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Wait ~2 minutes for the SSM agent to register, then:"
echo ""
echo "    aws ssm start-session \\"
echo "      --region ${REGION} \\"
echo "      --target ${BASTION_ID}"
echo ""
echo "  This opens a shell on the bastion without requiring port 22"
echo "  to be open to your machine. The bastion has a public IP and"
echo "  a NAT path so SSM can reach the AWS SSM endpoints."
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} STEP 2 — Verify the SSH key arrived on the bastion${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Once inside the SSM session on the bastion:"
echo ""
echo "    sudo cat /var/log/bastion-bootstrap.log"
echo ""
echo "  Confirms user data ran successfully and the key was pulled from S3."
echo ""
echo "    ls -la ~/.ssh/imds-keys/"
echo ""
echo "  You should see ${KEY_NAME}.pem with permissions 600."
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} STEP 3 — SSH from the bastion to the IMDS box${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  From inside the SSM session on the bastion:"
echo ""
echo "    ssh -i ~/.ssh/imds-keys/${KEY_NAME}.pem \\"
echo "      ec2-user@${IMDS_PRIVATE_IP}"
echo ""
echo "  This connects to the IMDS test box using its private IP."
echo "  The IMDS box security group allows SSH only from the bastion VPC CIDR."
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} STEP 4 — Verify the installer staged correctly on the IMDS box${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Once SSH'd onto the IMDS box:"
echo ""
echo "    sudo cat /var/log/imds-bootstrap.log"
echo ""
echo "  Confirms installer was pulled from S3 during boot."
echo ""
echo "    ls -la /opt/imds-proxy/"
echo ""
echo "  You should see imds-proxy-install-aws.sh ready to run."
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} STEP 5 — Install and start the IMDS proxy${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Still on the IMDS box:"
echo ""
echo "    sudo bash /opt/imds-proxy/imds-proxy-install-aws.sh"
echo ""
echo "  Installs the proxy, configures iptables, and starts the systemd service."
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} STEP 6 — Verify the proxy is working${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Check the service:"
echo ""
echo "    sudo systemctl status imds-proxy"
echo "    sudo journalctl -u imds-proxy -f"
echo "    sudo iptables -t nat -L OUTPUT -n -v"
echo ""
echo "  Run the region rewrite smoke test:"
echo ""
echo "    TOKEN=\$(curl -s -X PUT http://169.254.169.254/latest/api/token \\"
echo "      -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')"
echo ""
echo "    curl -s http://169.254.169.254/latest/meta-data/placement/region \\"
echo "      -H \"X-aws-ec2-metadata-token: \$TOKEN\""
echo "    # Expected: us-isob-east-1"
echo ""
echo "    curl -s http://169.254.169.254/latest/dynamic/instance-identity/document \\"
echo "      -H \"X-aws-ec2-metadata-token: \$TOKEN\" | python3 -m json.tool"
echo "    # Expected: region and availabilityZone show faux values"
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} TEAR DOWN${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Terminate both instances:"
echo "    aws ec2 terminate-instances \\"
echo "      --region ${REGION} \\"
echo "      --instance-ids ${BASTION_ID} ${IMDS_ID}"
echo ""
echo "  Remove S3 bucket:"
echo "    aws s3 rm s3://${S3_BUCKET} --recursive"
echo "    aws s3api delete-bucket --bucket ${S3_BUCKET} --region ${REGION}"
echo ""
echo "  Delete key pair (if created by this script):"
echo "    aws ec2 delete-key-pair --region ${REGION} --key-name ${KEY_NAME}"
echo "    rm -f ${KEY_FILE}"
echo ""
echo "  Delete security groups (after instances are terminated):"
echo "    aws ec2 delete-security-group --region ${REGION} --group-id ${BASTION_SG_ID}"
echo "    aws ec2 delete-security-group --region ${REGION} --group-id ${IMDS_SG_ID}"
echo ""
echo "  Delete IAM role and profile:"
echo "    aws iam remove-role-from-instance-profile \\"
echo "      --instance-profile-name ${PROFILE_NAME} --role-name ${ROLE_NAME}"
echo "    aws iam delete-instance-profile --instance-profile-name ${PROFILE_NAME}"
echo "    aws iam detach-role-policy --role-name ${ROLE_NAME} \\"
echo "      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
echo "    aws iam delete-role-policy \\"
echo "      --role-name ${ROLE_NAME} --policy-name ${TAG_PREFIX}-s3-scripts"
echo "    aws iam delete-role --role-name ${ROLE_NAME}"
echo ""