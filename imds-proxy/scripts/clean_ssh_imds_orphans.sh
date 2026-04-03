#!/bin/bash
##############################################################################
# clean_ssh_imds_orphans.sh
# Cleans up resources created by ssh_imds_bootstrap.sh.
#
# Loads state from ssh-imds-deploy-state.env if present, then does a live
# account scan to catch anything not reflected in the state file.
# Shows a full inventory first, then requires hard confirmation (typing the
# resource ID or name) before deleting ANYTHING.
#
# Usage: bash clean_ssh_imds_orphans.sh
##############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/ssh-imds-deploy-state.env"

# Defaults — overridden by state file if present
REGION="us-east-1"
TAG_PREFIX="imds-proxy"
BASTION_ID=""
IMDS_ID=""
S3_BUCKET=""
KEY_NAME=""
KEY_FILE=""
ROLE_NAME=""
PROFILE_NAME=""
BASTION_SG_ID=""
IMDS_SG_ID=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $1"; }
ok()     { echo -e "${GREEN}  ✓${NC} $1"; }
skip()   { echo -e "${YELLOW}  -${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()    { echo -e "${RED}  ✗${NC} $1"; }
mark()   { echo -e "  ${RED}[DELETE]${NC} $1"; }
header() { echo ""; echo -e "${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }
divider(){ echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# =============================================================================
# Hard confirmation — caller must type the exact token to proceed
# =============================================================================
confirm_hard() {
    local prompt="$1"
    local token="$2"
    echo ""
    divider
    echo -e "${RED}  ${prompt}${NC}"
    echo ""
    echo -e "  To confirm, type exactly:  ${BOLD}${token}${NC}"
    divider
    echo ""
    read -r -p "  > " REPLY
    echo ""
    [[ "${REPLY}" == "${token}" ]]
}

# =============================================================================
# Load state file
# =============================================================================
header "State file"
if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    ok "Loaded: ${STATE_FILE}"
    # Derive names from TAG_PREFIX if state file doesn't include them
    ROLE_NAME="${ROLE_NAME:-${TAG_PREFIX}-role}"
    PROFILE_NAME="${PROFILE_NAME:-${TAG_PREFIX}-profile}"
else
    warn "State file not found: ${STATE_FILE}"
    warn "Proceeding with tag-based discovery only."
    ROLE_NAME="${TAG_PREFIX}-role"
    PROFILE_NAME="${TAG_PREFIX}-profile"
fi

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account --output text 2>/dev/null || echo "")
[[ -z "${ACCOUNT_ID}" ]] && {
    echo -e "${RED}[ERROR]${NC} Cannot authenticate to AWS. Exiting." ; exit 1
}
S3_BUCKET="${S3_BUCKET:-${TAG_PREFIX}-scripts-${ACCOUNT_ID}}"

# =============================================================================
# INVENTORY — EC2 instances
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║         FULL ACCOUNT INVENTORY (read-only)          ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

header "EC2 Instances (tagged ${TAG_PREFIX}-bastion or ${TAG_PREFIX}-imds-box)"

# Discover by tag — catches instances even if state file is stale/missing
mapfile -t LIVE_INSTANCES < <(
    aws ec2 describe-instances \
        --region "${REGION}" \
        --filters \
            "Name=tag:Name,Values=${TAG_PREFIX}-bastion,${TAG_PREFIX}-imds-box" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key=='Name']|[0].Value]" \
        --output text 2>/dev/null || true
)

# Also include any IDs from state file that may have been missed by tag filter
# (e.g. already stopping/terminating)
for sid in "${BASTION_ID}" "${IMDS_ID}"; do
    [[ -z "${sid}" ]] && continue
    if ! printf '%s\n' "${LIVE_INSTANCES[@]}" | grep -q "${sid}"; then
        EXTRA=$(aws ec2 describe-instances \
            --region "${REGION}" \
            --instance-ids "${sid}" \
            --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key=='Name']|[0].Value]" \
            --output text 2>/dev/null || true)
        [[ -n "${EXTRA}" ]] && LIVE_INSTANCES+=("${EXTRA}")
    fi
done

if [[ ${#LIVE_INSTANCES[@]} -eq 0 ]]; then
    echo "  (none found)"
else
    for row in "${LIVE_INSTANCES[@]}"; do
        mark "${row}"
    done
fi

# =============================================================================
# INVENTORY — Security groups
# =============================================================================
header "Security Groups"

SG_ROWS=()
for sgid in "${BASTION_SG_ID:-}" "${IMDS_SG_ID:-}"; do
    [[ -z "${sgid}" ]] && continue
    row=$(aws ec2 describe-security-groups \
        --region "${REGION}" \
        --group-ids "${sgid}" \
        --query "SecurityGroups[0].[GroupId,GroupName,VpcId]" \
        --output text 2>/dev/null || true)
    [[ -n "${row}" ]] && SG_ROWS+=("${row}")
done

# Also scan by name in case state file IDs are missing
for sgname in "${TAG_PREFIX}-bastion-sg" "${TAG_PREFIX}-imds-sg"; do
    row=$(aws ec2 describe-security-groups \
        --region "${REGION}" \
        --filters "Name=group-name,Values=${sgname}" \
        --query "SecurityGroups[0].[GroupId,GroupName,VpcId]" \
        --output text 2>/dev/null || true)
    if [[ -n "${row}" && "${row}" != "None" ]]; then
        sgid_found=$(awk '{print $1}' <<< "${row}")
        if ! printf '%s\n' "${SG_ROWS[@]}" | grep -q "${sgid_found}"; then
            SG_ROWS+=("${row}")
        fi
    fi
done

if [[ ${#SG_ROWS[@]} -eq 0 ]]; then
    echo "  (none found)"
else
    for row in "${SG_ROWS[@]}"; do
        mark "${row}"
    done
fi

# =============================================================================
# INVENTORY — IAM
# =============================================================================
header "IAM Role: ${ROLE_NAME}"
ROLE_EXISTS=$(aws iam get-role \
    --role-name "${ROLE_NAME}" \
    --query "Role.[RoleName,RoleId,CreateDate]" \
    --output text 2>/dev/null || echo "")
[[ -n "${ROLE_EXISTS}" ]] && mark "${ROLE_EXISTS}" || echo "  (not found)"

header "IAM Instance Profile: ${PROFILE_NAME}"
PROFILE_EXISTS=$(aws iam get-instance-profile \
    --instance-profile-name "${PROFILE_NAME}" \
    --query "InstanceProfile.[InstanceProfileName,InstanceProfileId]" \
    --output text 2>/dev/null || echo "")
[[ -n "${PROFILE_EXISTS}" ]] && mark "${PROFILE_EXISTS}" || echo "  (not found)"

# =============================================================================
# INVENTORY — Key pair
# =============================================================================
header "Key Pair: ${KEY_NAME:-"(not in state file)"}"
if [[ -n "${KEY_NAME:-}" ]]; then
    KP_EXISTS=$(aws ec2 describe-key-pairs \
        --region "${REGION}" \
        --key-names "${KEY_NAME}" \
        --query "KeyPairs[0].[KeyName,KeyPairId]" \
        --output text 2>/dev/null || echo "")
    [[ -n "${KP_EXISTS}" ]] && mark "${KP_EXISTS}" || echo "  (not found in AWS)"
    if [[ -n "${KEY_FILE:-}" && -f "${KEY_FILE}" ]]; then
        mark "Local file: ${KEY_FILE}"
    else
        echo "  Local file: (not found)"
    fi
else
    echo "  (no key name in state file — skipping)"
fi

# =============================================================================
# INVENTORY — S3
# =============================================================================
header "S3 Bucket: ${S3_BUCKET}"
S3_EXISTS=$(aws s3api head-bucket \
    --bucket "${S3_BUCKET}" \
    --region "${REGION}" 2>/dev/null && echo "yes" || echo "no")
if [[ "${S3_EXISTS}" == "yes" ]]; then
    S3_SIZE=$(aws s3 ls "s3://${S3_BUCKET}/" --recursive \
        --region "${REGION}" 2>/dev/null \
        | awk '{sum += $3} END {print sum+0}')
    mark "s3://${S3_BUCKET}  (~${S3_SIZE} bytes)"
else
    echo "  (not found)"
fi

# =============================================================================
# INVENTORY — State file and key file
# =============================================================================
header "Local files"
[[ -f "${STATE_FILE}" ]]      && mark "${STATE_FILE}"   || echo "  State file: (not found)"
[[ -n "${KEY_FILE:-}" && -f "${KEY_FILE}" ]] \
    && mark "${KEY_FILE}" \
    || echo "  Key file: (not found or not in state)"

# =============================================================================
echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║   INVENTORY COMPLETE — DELETIONS BEGIN BELOW        ║${NC}"
echo -e "${BOLD}${RED}║   Each group requires you to type the exact token.  ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════╝${NC}"

# =============================================================================
# GROUP 1 — EC2 Instances
# Must terminate before SGs can be deleted.
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           GROUP 1 — EC2 INSTANCES                   ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

if [[ ${#LIVE_INSTANCES[@]} -eq 0 ]]; then
    info "No instances to terminate — skipping."
else
    echo ""
    echo "  Instances to be TERMINATED:"
    INSTANCE_IDS=()
    for row in "${LIVE_INSTANCES[@]}"; do
        iid=$(awk '{print $1}' <<< "${row}")
        INSTANCE_IDS+=("${iid}")
        echo -e "  ${RED}•${NC} ${row}"
    done
    echo ""

    ID_LIST="${INSTANCE_IDS[*]}"
    if confirm_hard \
        "Type the bastion instance ID to confirm termination of ALL listed instances:" \
        "${INSTANCE_IDS[0]}"; then
        aws ec2 terminate-instances \
            --region "${REGION}" \
            --instance-ids "${INSTANCE_IDS[@]}" >/dev/null
        info "Waiting for instances to terminate (this may take ~60s)..."
        aws ec2 wait instance-terminated \
            --region "${REGION}" \
            --instance-ids "${INSTANCE_IDS[@]}"
        ok "Instances terminated."
    else
        warn "Confirmation did not match — instances NOT terminated."
        warn "Security groups cannot be deleted until instances are terminated."
        warn "Re-run this script after manually terminating instances."
    fi
fi

# =============================================================================
# GROUP 2 — Security Groups
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           GROUP 2 — SECURITY GROUPS                 ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

if [[ ${#SG_ROWS[@]} -eq 0 ]]; then
    info "No security groups found — skipping."
else
    echo ""
    echo "  Security groups to be DELETED:"
    SG_IDS=()
    SG_NAMES=()
    for row in "${SG_ROWS[@]}"; do
        sgid=$(awk '{print $1}' <<< "${row}")
        sgname=$(awk '{print $2}' <<< "${row}")
        SG_IDS+=("${sgid}")
        SG_NAMES+=("${sgname}")
        echo -e "  ${RED}•${NC} ${row}"
    done
    echo ""

    for i in "${!SG_IDS[@]}"; do
        sgid="${SG_IDS[$i]}"
        sgname="${SG_NAMES[$i]}"
        if confirm_hard \
            "Type the security group ID to confirm deletion of ${sgname}:" \
            "${sgid}"; then
            aws ec2 delete-security-group \
                --region "${REGION}" \
                --group-id "${sgid}" 2>/dev/null \
                && ok "Deleted: ${sgname} (${sgid})" \
                || err "Failed to delete ${sgid} — may still have dependent instances"
        else
            warn "Confirmation did not match — ${sgname} (${sgid}) NOT deleted."
        fi
    done
fi

# =============================================================================
# GROUP 3 — IAM
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           GROUP 3 — IAM RESOURCES                   ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

if [[ -z "${ROLE_EXISTS}" && -z "${PROFILE_EXISTS}" ]]; then
    info "No IAM resources found — skipping."
else
    echo ""
    echo "  IAM resources to be DELETED:"
    [[ -n "${PROFILE_EXISTS}" ]] && echo -e "  ${RED}•${NC} Instance profile : ${PROFILE_NAME}"
    [[ -n "${ROLE_EXISTS}" ]]    && echo -e "  ${RED}•${NC} Inline policy     : ${TAG_PREFIX}-s3-scripts"
    [[ -n "${ROLE_EXISTS}" ]]    && echo -e "  ${RED}•${NC} Managed policy    : AmazonSSMManagedInstanceCore (detach)"
    [[ -n "${ROLE_EXISTS}" ]]    && echo -e "  ${RED}•${NC} IAM role          : ${ROLE_NAME}"
    echo ""

    if confirm_hard \
        "Type the IAM role name to confirm deletion of the role and profile:" \
        "${ROLE_NAME}"; then

        aws iam remove-role-from-instance-profile \
            --instance-profile-name "${PROFILE_NAME}" \
            --role-name "${ROLE_NAME}" 2>/dev/null \
            && ok "Role removed from instance profile" \
            || skip "Association not found"

        aws iam delete-instance-profile \
            --instance-profile-name "${PROFILE_NAME}" 2>/dev/null \
            && ok "Instance profile deleted: ${PROFILE_NAME}" \
            || skip "Profile not found"

        aws iam delete-role-policy \
            --role-name "${ROLE_NAME}" \
            --policy-name "${TAG_PREFIX}-s3-scripts" 2>/dev/null \
            && ok "Inline S3 policy deleted" \
            || skip "Inline policy not found"

        aws iam detach-role-policy \
            --role-name "${ROLE_NAME}" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null \
            && ok "Managed policy detached" \
            || skip "Policy not attached"

        aws iam delete-role \
            --role-name "${ROLE_NAME}" 2>/dev/null \
            && ok "IAM role deleted: ${ROLE_NAME}" \
            || skip "Role not found"
    else
        warn "Confirmation did not match — IAM resources NOT deleted."
    fi
fi

# =============================================================================
# GROUP 4 — Key pair
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           GROUP 4 — KEY PAIR                        ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

if [[ -z "${KEY_NAME:-}" ]]; then
    info "No key name in state file — skipping."
else
    KP_EXISTS=$(aws ec2 describe-key-pairs \
        --region "${REGION}" \
        --key-names "${KEY_NAME}" \
        --query "KeyPairs[0].KeyName" \
        --output text 2>/dev/null || echo "")

    if [[ -z "${KP_EXISTS}" || "${KP_EXISTS}" == "None" ]] \
        && [[ ! -f "${KEY_FILE:-/dev/null}" ]]; then
        info "Key pair not found in AWS and no local file — skipping."
    else
        echo ""
        [[ -n "${KP_EXISTS}" ]] && \
            echo -e "  ${RED}•${NC} AWS key pair : ${KEY_NAME}"
        [[ -n "${KEY_FILE:-}" && -f "${KEY_FILE}" ]] && \
            echo -e "  ${RED}•${NC} Local file   : ${KEY_FILE}"
        echo ""

        if confirm_hard \
            "Type the key pair name to confirm deletion of ${KEY_NAME}:" \
            "${KEY_NAME}"; then

            if [[ -n "${KP_EXISTS}" && "${KP_EXISTS}" != "None" ]]; then
                aws ec2 delete-key-pair \
                    --region "${REGION}" \
                    --key-name "${KEY_NAME}" 2>/dev/null \
                    && ok "AWS key pair deleted: ${KEY_NAME}" \
                    || err "Failed to delete AWS key pair"
            fi

            if [[ -n "${KEY_FILE:-}" && -f "${KEY_FILE}" ]]; then
                rm -f "${KEY_FILE}" \
                    && ok "Local key file deleted: ${KEY_FILE}" \
                    || err "Failed to delete local key file"
                KEY_DIR="$(dirname "${KEY_FILE}")"
                if [[ -d "${KEY_DIR}" && -z "$(ls -A "${KEY_DIR}")" ]]; then
                    rmdir "${KEY_DIR}" \
                        && ok "Empty keys/ directory removed: ${KEY_DIR}" \
                        || err "Failed to remove keys/ directory"
                fi
            fi
        else
            warn "Confirmation did not match — key pair NOT deleted."
        fi
    fi
fi

# =============================================================================
# GROUP 5 — S3 bucket
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           GROUP 5 — S3 BUCKET                       ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

if [[ "${S3_EXISTS}" != "yes" ]]; then
    info "S3 bucket not found — skipping."
else
    echo ""
    echo -e "  ${RED}•${NC} All objects in s3://${S3_BUCKET}/"
    echo -e "  ${RED}•${NC} Bucket: ${S3_BUCKET}"
    echo ""

    if confirm_hard \
        "Type the bucket name to confirm permanent deletion of all contents:" \
        "${S3_BUCKET}"; then
        aws s3 rm "s3://${S3_BUCKET}" --recursive --region "${REGION}" >/dev/null \
            && ok "Bucket contents deleted" \
            || err "Failed to empty bucket"
        aws s3api delete-bucket \
            --bucket "${S3_BUCKET}" \
            --region "${REGION}" 2>/dev/null \
            && ok "Bucket deleted: ${S3_BUCKET}" \
            || err "Failed to delete bucket"
    else
        warn "Confirmation did not match — S3 bucket NOT deleted."
    fi
fi

# =============================================================================
# GROUP 6 — Local state file
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           GROUP 6 — LOCAL STATE FILE                ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

if [[ ! -f "${STATE_FILE}" ]]; then
    info "State file not found — skipping."
else
    echo ""
    echo -e "  ${RED}•${NC} ${STATE_FILE}"
    echo ""

    if confirm_hard \
        "Type DELETE to remove the local state file:" \
        "DELETE"; then
        rm -f "${STATE_FILE}" && ok "State file removed."
    else
        warn "Confirmation did not match — state file NOT removed."
    fi
fi

# =============================================================================
# Done
# =============================================================================
echo ""
info "Cleanup complete."
echo ""