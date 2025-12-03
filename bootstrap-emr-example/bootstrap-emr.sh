#!/bin/bash

set -euo pipefail

REGION="us-iso-east-1"
CA_DEST="/etc/pki/ca-trust/source/anchors/combine-ca-chain.pem"
ENV_SCRIPT="/etc/profile.d/combine-high-side.sh"
EMR_ENDPOINT="https://elasticmapreduce.${REGION}.c2s.ic.gov"
S3_ENDPOINT="https://s3.${REGION}.c2s.ic.gov"
STS_ENDPOINT="https://sts.${REGION}.c2s.ic.gov"
LOG_PREFIX="[combine-emr-bootstrap]"

# These are set from bootstrap action arguments in main()
SHARD_ID_LOWERCASE=""
ACCOUNT_ID=""
COMM_REGION=""

log() {
	echo "${LOG_PREFIX} $*"
}

install_combine_ca() {
	local dest_dir bucket key tmpfile
	dest_dir="$(dirname "${CA_DEST}")"
	bucket="combine-${SHARD_ID_LOWERCASE}-devops-${ACCOUNT_ID}-${COMM_REGION}"
	key="certificates/ca-chain.cert.pem"
	tmpfile="$(mktemp)"

	log "Installing Combine CA bundle to ${CA_DEST}"
	log "Downloading CA bundle from s3://${bucket}/${key} (region ${COMM_REGION})"

	aws s3 cp "s3://${bucket}/${key}" "${tmpfile}" --region "${COMM_REGION}"

	sudo mkdir -p "${dest_dir}"
	sudo cp "${tmpfile}" "${CA_DEST}"
	sudo chmod 0644 "${CA_DEST}"
	rm -f "${tmpfile}"
}

refresh_trust_store() {
	log "Refreshing system trust store"
	if command -v update-ca-trust >/dev/null 2>&1; then
		sudo update-ca-trust extract
	elif command -v update-ca-certificates >/dev/null 2>&1; then
		sudo update-ca-certificates
	else
		log "No trust store refresh command found; continuing"
	fi
}

write_env_script() {
	log "Writing environment exports to ${ENV_SCRIPT}"
	sudo tee "${ENV_SCRIPT}" >/dev/null <<EOF
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"
export AWS_CA_BUNDLE="${CA_DEST}"
export COMBINE_HIGH_SIDE_EMR_ENDPOINT="${EMR_ENDPOINT}"
export COMBINE_HIGH_SIDE_S3_ENDPOINT="${S3_ENDPOINT}"
export COMBINE_HIGH_SIDE_STS_ENDPOINT="${STS_ENDPOINT}"
EOF
	sudo chmod 0644 "${ENV_SCRIPT}"
}

write_system_environment() {
	local env_file="/etc/environment"
	log "Ensuring /etc/environment carries AWS defaults"
	if [ ! -f "${env_file}" ]; then
		echo "# Created by Combine EMR bootstrap" | sudo tee "${env_file}" >/dev/null
	fi
	sudo cp "${env_file}" "${env_file}.combine.bak" || true
	if sudo grep -q '^AWS_REGION=' "${env_file}"; then
		sudo sed -i "s|^AWS_REGION=.*|AWS_REGION=${REGION}|" "${env_file}"
	else
		echo "AWS_REGION=${REGION}" | sudo tee -a "${env_file}" >/dev/null
	fi
	if sudo grep -q '^AWS_DEFAULT_REGION=' "${env_file}"; then
		sudo sed -i "s|^AWS_DEFAULT_REGION=.*|AWS_DEFAULT_REGION=${REGION}|" "${env_file}"
	else
		echo "AWS_DEFAULT_REGION=${REGION}" | sudo tee -a "${env_file}" >/dev/null
	fi
	if sudo grep -q '^AWS_CA_BUNDLE=' "${env_file}"; then
		sudo sed -i "s|^AWS_CA_BUNDLE=.*|AWS_CA_BUNDLE=${CA_DEST}|" "${env_file}"
	else
		echo "AWS_CA_BUNDLE=${CA_DEST}" | sudo tee -a "${env_file}" >/dev/null
	fi
}

configure_aws_cli_for_user() {
	local user="$1"
	local home_dir
	if ! id "$user" &>/dev/null; then
		return
	fi
	home_dir="$(eval echo "~$user")"
	local aws_dir="${home_dir}/.aws"
	log "Configuring AWS CLI defaults for ${user}"
	sudo mkdir -p "${aws_dir}"
	sudo tee "${aws_dir}/config" >/dev/null <<EOF
[default]
region = ${REGION}
ca_bundle = ${CA_DEST}
s3 =
	endpoint_url = ${S3_ENDPOINT}

[profile combine-emr]
region = ${REGION}
ca_bundle = ${CA_DEST}
s3 =
	endpoint_url = ${S3_ENDPOINT}
EOF
	sudo chmod 0600 "${aws_dir}/config"
	sudo chown -R "${user}:${user}" "${aws_dir}"
}

main() {
	if [ "$#" -ne 3 ]; then
		log "Usage: $0 <ShardIdLowerCase> <AccountId> <CommercialRegion>"
		exit 1
	fi

	SHARD_ID_LOWERCASE="$1"
	ACCOUNT_ID="$2"
	COMM_REGION="$3"

	install_combine_ca
	refresh_trust_store
	write_env_script
	write_system_environment
	configure_aws_cli_for_user root
	configure_aws_cli_for_user hadoop
	configure_aws_cli_for_user ec2-user
	log "Bootstrap complete. New shells will automatically use the ISO region and CA bundle."
}

main "$@"
