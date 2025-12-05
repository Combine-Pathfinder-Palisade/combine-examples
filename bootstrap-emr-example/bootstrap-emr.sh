#!/bin/bash

set -euo pipefail

REGION="us-iso-east-1"
CA_DEST="/etc/pki/ca-trust/source/anchors/combine-ca-chain.pem"
ENV_SCRIPT="/etc/profile.d/combine-env.sh"
LOG_PREFIX="[combine-emr-bootstrap]"

# These are set from bootstrap action arguments in main()
SHARD_ID=""
ACCOUNT_ID=""
HOST_REGION=""

log() {
	echo "${LOG_PREFIX} $*"
}

install_combine_ca() {
	local dest_dir bucket key tmpfile
	dest_dir="$(dirname "${CA_DEST}")"
	bucket="combine-${SHARD_ID}-devops-${ACCOUNT_ID}-${HOST_REGION}"
	key="certificates/ca-chain.cert.pem"
	tmpfile="$(mktemp)"

	log "Installing Combine CA bundle to ${CA_DEST}"
	log "Downloading CA bundle from s3://${bucket}/${key} (region ${HOST_REGION})"

	aws s3 cp "s3://${bucket}/${key}" "${tmpfile}" --region "${HOST_REGION}"

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
EOF
	sudo chmod 0644 "${ENV_SCRIPT}"
}

configure_aws_cli_for_root() {
	local home_dir="$(eval echo "~root")"
	local aws_dir="${home_dir}/.aws"
	log "Configuring AWS CLI defaults for root"
	sudo mkdir -p "${aws_dir}"
	sudo tee "${aws_dir}/config" >/dev/null <<EOF
[default]
region = ${REGION}
ca_bundle = ${CA_DEST}
EOF
}

main() {
	if [ "$#" -ne 3 ]; then
		log "Usage: $0 <ShardIdLowerCase> <AccountId> <CommercialRegion>"
		exit 1
	fi

	SHARD_ID="$1"
	ACCOUNT_ID="$2"
	HOST_REGION="$3"

	install_combine_ca
	refresh_trust_store
	write_env_script
	configure_aws_cli_for_root
	log "Bootstrap complete."
}

main "$@"
