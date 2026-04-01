echo "Looking up CloudFormation stack matching 'Combine-*-Policy'..."

mapfile -t STACK_MATCHES < <(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?starts_with(StackName, 'Combine-') && ends_with(StackName, '-Policy')].StackName" \
  --output text | tr '\t' '\n')

if [[ ${#STACK_MATCHES[@]} -eq 0 || -z "${STACK_MATCHES[0]}" ]]; then
    echo "Error: No stack matching 'Combine-*-Policy' found. Please verify your AWS credentials and region."
    exit 1
elif [[ ${#STACK_MATCHES[@]} -eq 1 ]]; then
    STACK_NAME="${STACK_MATCHES[0]}"
else
    echo "Multiple matching stacks found:"
    for i in "${!STACK_MATCHES[@]}"; do
        echo "  $((i+1))) ${STACK_MATCHES[$i]}"
    done
    echo "Select a stack (1-${#STACK_MATCHES[@]}):"
    read -r STACK_CHOICE
    if ! [[ "$STACK_CHOICE" =~ ^[0-9]+$ ]] || (( STACK_CHOICE < 1 || STACK_CHOICE > ${#STACK_MATCHES[@]} )); then
        echo "Error: Invalid selection."
        exit 1
    fi
    STACK_NAME="${STACK_MATCHES[$((STACK_CHOICE-1))]}"
fi

echo "Checking CloudFormation stack: $STACK_NAME"

STACK_PARAMS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Parameters[?ParameterKey=='EnableRoleHierarchyC2E' || ParameterKey=='EnableRoleHierarchyC2EPermissionBoundary' || ParameterKey=='EnableRoleHierarchyC2ESelfService']" \
  --output json)

if [[ $? -ne 0 ]]; then
    echo "Error: Failed to query CloudFormation stack '$STACK_NAME'. Please verify your AWS credentials."
    exit 1
fi

echo "CloudFormation Parameters:"
echo "$STACK_PARAMS"

DISABLED_PARAMS=()
while IFS= read -r line; do
    PARAM_KEY=$(echo "$line" | jq -r '.ParameterKey')
    PARAM_VALUE=$(echo "$line" | jq -r '.ParameterValue')

    if [[ "$PARAM_VALUE" != "true" ]]; then
        DISABLED_PARAMS+=("$PARAM_KEY")
    fi
done < <(echo "$STACK_PARAMS" | jq -c '.[]')

if [[ ${#DISABLED_PARAMS[@]} -gt 0 ]]; then
    echo ""
    echo "The following required parameters are disabled in stack $STACK_NAME:"
    for param in "${DISABLED_PARAMS[@]}"; do
        echo "  - $param"
    done
    echo ""
    echo "Would you like to enable these parameters automatically? (y/n)"
    read -r ENABLE_CHOICE

    if [[ "$ENABLE_CHOICE" =~ ^[Yy]$ ]]; then
        echo "Enabling disabled parameters..."

        UPDATE_PARAMS=""
        for param in "${DISABLED_PARAMS[@]}"; do
            UPDATE_PARAMS="$UPDATE_PARAMS ParameterKey=$param,ParameterValue=true"
        done

        echo "Updating CloudFormation stack with enabled parameters..."
        aws cloudformation update-stack \
            --stack-name "$STACK_NAME" \
            --use-previous-template \
            --parameters $UPDATE_PARAMS \
            --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM

        if [[ $? -eq 0 ]]; then
            echo "Stack update initiated. Waiting for completion..."
            aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME"

            if [[ $? -eq 0 ]]; then
                echo "Stack update completed successfully. Required parameters are now enabled."
            else
                echo "Stack update failed. Please check the CloudFormation console and enable parameters manually."
                exit 1
            fi
        else
            echo "Failed to update stack. Please enable parameters manually in the CloudFormation console."
            exit 1
        fi
    else
        echo "Please enable these parameters in your CloudFormation stack before proceeding."
        exit 1
    fi
fi

echo "All required role hierarchy parameters are enabled. Proceeding with installation..."

echo "Proceeding with system updates and dependency installation..."

firewall_error() {
    echo ""
    echo "Error: '$1' failed. This may be caused by a network timeout or firewall block."
    echo "Please ensure your firewall is set to Permissive mode and try again."
    echo "If you're unsure how to do this, please ask a Combine Team member for assistance."
    exit 1
}

sudo yum update -y || firewall_error "yum update"
sudo yum upgrade -y || firewall_error "yum upgrade"
sudo yum update --security -y || firewall_error "yum update --security"
# Install dependencies
## Git
sudo yum install git -y || firewall_error "yum install git"
## Helm 3
echo "Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || firewall_error "Helm install"
## Kubectl
echo "Installing Kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" || firewall_error "kubectl download"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
## Kubectx
echo "Installing Kubectx..."
sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx || firewall_error "kubectx clone"
sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
## Terraform
echo "Installing Terraform..."
sudo yum install -y yum-utils || firewall_error "yum install yum-utils"
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo || firewall_error "yum-config-manager"
sudo yum -y install terraform || firewall_error "yum install terraform"
## Terragrunt
echo "Installing Terragrunt..."
curl -L https://github.com/gruntwork-io/terragrunt/releases/latest/download/terragrunt_linux_amd64 -o terragrunt || firewall_error "terragrunt download"
sudo install -o root -g root -m 0755 terragrunt /usr/local/bin/terragrunt
rm terragrunt