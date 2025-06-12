#!/bin/bash

# Exit on error
set -e

# === Configuration Variables ===
CUSTOM_CA_SOURCE_PATH="/etc/pki/ca-trust/source/anchors/custom-cert.pem"
CUSTOM_CA_FILE="custom-cert.pem"
SSM_ENDPOINT="https://example-endpoint-url"
REGION="example-region"

# === Constants === #
CUSTOM_CA_DEST_PATH="/etc/amazon/ssm/custom-certs"
SSM_CONFIG_FILE="/etc/amazon/ssm/amazon-ssm-agent.json"

# === Ensure SSM Agent is installed ===
echo "[*] Installing amazon-ssm-agent..."
if ! command -v amazon-ssm-agent &> /dev/null; then
  sudo yum install -y amazon-ssm-agent
else
  echo "    Already installed."
fi

# === Create directory for custom CA ===
echo "[*] Creating custom cert directory..."
sudo mkdir -p "$CUSTOM_CA_DEST_PATH"

# === Copy CA cert into place ===
echo "[*] Copying custom CA certificate from $CUSTOM_CA_SOURCE_PATH"
if [ ! -f "$CUSTOM_CA_SOURCE_PATH" ]; then
  echo "[ERROR] PEM file not found at $CUSTOM_CA_SOURCE_PATH"
  exit 1
fi
sudo cp "$CUSTOM_CA_SOURCE_PATH" "$CUSTOM_CA_DEST_PATH/$CUSTOM_CA_FILE"
sudo chmod 644 "$CUSTOM_CA_DEST_PATH/$CUSTOM_CA_FILE"

# === Write amazon-ssm-agent.json config ===
echo "[*] Configuring amazon-ssm-agent..."
sudo tee "$SSM_CONFIG_FILE" > /dev/null <<EOF
{
  "region": "$REGION",
  "endpoint": "$SSM_ENDPOINT",
  "caBundlePath": "$CUSTOM_CA_DEST_PATH/$CUSTOM_CA_FILE"
}
EOF

# === Restart and enable SSM Agent ===
echo "[*] Restarting amazon-ssm-agent..."
sudo systemctl daemon-reexec || true
sudo systemctl restart amazon-ssm-agent
sudo systemctl enable amazon-ssm-agent

# === Final Check ===
echo "[*] Verifying agent status..."
sudo systemctl status amazon-ssm-agent --no-pager

echo "[✓] SSM Agent successfully bootstrapped with custom endpoint and CA."