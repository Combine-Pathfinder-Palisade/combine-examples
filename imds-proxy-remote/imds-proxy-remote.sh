#!/bin/bash
##############################################################################
# imds-proxy-remote.sh
# Self-contained installer for the Combine AWS IMDS Proxy.
#
# Note that this proxy is EXPERIMENTAL, and in development. Please report any
# bugs to the Combine team at service-request@sequoiainc.com
#
# This variant is designed to run on a single dedicated host that
# serves IMDS responses to OTHER EC2 instances over the VPC. Client
# instances point at this host via:
#
#     export AWS_EC2_METADATA_SERVICE_ENDPOINT=http://<this-host-ip>:8090
#
# Differences from the local installer:
#   - No iptables NAT redirect (the proxy receives traffic directly on 8090)
#   - No SO_MARK / fwmark logic (not needed without iptables)
#   - LISTEN_ADDR is configurable (default 0.0.0.0)
#   - Smoke test calls the proxy directly on its listen port
#   - Performs a clean reinstall every run (removes the script and the
#     systemd unit before recreating them)
#
# SECURITY WARNING:
#   Any host that can reach LISTEN_ADDR:LISTEN_PORT can obtain IMDSv2
#   credentials for THIS host's IAM role. Restrict access via security
#   groups / NACLs to only the client instances that should share this
#   role. CloudTrail will attribute all client API calls to this host's
#   role and instance ID.
#
# Usage: sudo bash imds-proxy-remote.sh [--<commercial-region>=<faux-region> ...]
#
# Faux region values (symbolic name or literal string both accepted):
#   SC2S_REGION     -> us-isob-east-1  (AWS Secret Region)
#   C2S_REGION_EAST -> us-iso-east-1   (AWS Top Secret East)
#   C2S_REGION_WEST -> us-iso-west-1   (AWS Top Secret West)
#
# Examples:
#   sudo bash imds-proxy-remote.sh
#   sudo bash imds-proxy-remote.sh --us-east-1=SC2S_REGION
#   sudo bash imds-proxy-remote.sh --us-east-1=C2S_REGION_EAST --us-west-2=C2S_REGION_WEST
##############################################################################

set -euo pipefail

PROXY_DST="/usr/local/bin/imds-proxy.py"
SERVICE_NAME="imds-proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="/var/log/imds-proxy.log"

# Listen address/port for the proxy. 0.0.0.0 binds all interfaces; set to a
# specific private IP if you want to restrict to one NIC.
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-8090}"

# =============================================================================
# Argument parsing: --<commercial-region>=<faux-region>
# =============================================================================
_sc2s_r="us-isob-east-1"
_c2s_r_east="us-iso-east-1"
_c2s_r_west="us-iso-west-1"

_resolve_faux_region() {
    case "$1" in
        SC2S_REGION)                        echo "${_sc2s_r}"      ;;
        C2S_REGION_EAST)                    echo "${_c2s_r_east}"  ;;
        C2S_REGION_WEST)                    echo "${_c2s_r_west}"  ;;
        us-isob-east-1|us-iso-east-1|us-iso-west-1) echo "$1"     ;;
        *) echo "ERROR: Unknown faux region '$1'. Valid values: SC2S_REGION, C2S_REGION_EAST, C2S_REGION_WEST" >&2; exit 1 ;;
    esac
}

declare -A _region_map_args=()
for _arg in "$@"; do
    if [[ "${_arg}" =~ ^--([a-z0-9-]+)=(.+)$ ]]; then
        _comm="${BASH_REMATCH[1]}"
        _faux=$(_resolve_faux_region "${BASH_REMATCH[2]}")
        _region_map_args["${_comm}"]="${_faux}"
    else
        echo "ERROR: Unrecognized argument '${_arg}'. Expected --<commercial-region>=<faux-region>" >&2
        exit 1
    fi
done

if [[ ${#_region_map_args[@]} -eq 0 ]]; then
    REGION_MAP_PYTHON="{\"us-east-1\": \"${_sc2s_r}\"}"
else
    _rmap_entries=""
    for _comm in "${!_region_map_args[@]}"; do
        [[ -n "${_rmap_entries}" ]] && _rmap_entries+=", "
        _rmap_entries+="\"${_comm}\": \"${_region_map_args[${_comm}]}\""
    done
    REGION_MAP_PYTHON="{${_rmap_entries}}"
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
ok()    { echo -e "${GREEN}  ✓${NC} $1"; }

# =============================================================================
# Preflight
# =============================================================================
info "Running preflight checks..."

[[ $EUID -eq 0 ]] || error "This script must be run as root."

command -v python3 >/dev/null 2>&1 || {
    warn "python3 not found — attempting to install..."
    if command -v yum >/dev/null 2>&1; then
        yum install -y python3 || error "Failed to install python3 via yum"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y python3 || error "Failed to install python3 via apt"
    else
        error "Cannot install python3 — no supported package manager found"
    fi
}

command -v systemctl >/dev/null 2>&1 || error "systemd not found on this system."

ok "Preflight checks passed"

# =============================================================================
# Clean reinstall: stop, disable, and remove any prior installation
# =============================================================================
info "Performing clean reinstall (removing any prior installation)..."

if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    info "Stopping ${SERVICE_NAME} service..."
    systemctl stop "${SERVICE_NAME}"
    ok "Service stopped"
fi

if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    info "Disabling ${SERVICE_NAME} service..."
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    ok "Service disabled"
fi

if [[ -f "${SERVICE_FILE}" ]]; then
    info "Removing systemd unit file ${SERVICE_FILE}..."
    rm -f "${SERVICE_FILE}"
    ok "Unit file removed"
fi

# Reset any failed-state and reload so systemd forgets the old unit
systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
systemctl daemon-reload

if [[ -f "${PROXY_DST}" ]]; then
    info "Removing existing proxy script ${PROXY_DST}..."
    rm -f "${PROXY_DST}"
    ok "Proxy script removed"
fi

# =============================================================================
# Best-effort cleanup of any lingering iptables rules from a prior local install
# =============================================================================
if command -v iptables >/dev/null 2>&1; then
    info "Cleaning up any pre-existing local-mode iptables rules..."
    for rule in \
        "OUTPUT -p tcp -d 169.254.169.254 --dport 80 -m mark --mark 100 -j RETURN" \
        "OUTPUT -p tcp -d 169.254.169.254 --dport 80 -j REDIRECT --to-port ${LISTEN_PORT}" \
        "OUTPUT -p tcp -d 169.254.169.254 --dport 80 -j REDIRECT --to-port 8090"
    do
        # Loop in case the rule was added more than once
        while iptables -t nat -C ${rule} 2>/dev/null; do
            iptables -t nat -D ${rule} 2>/dev/null || break
        done
    done
    ok "iptables cleanup complete (no-op if no rules existed)"
fi

# =============================================================================
# Write proxy script (config block, with shell variable substitution)
# =============================================================================
info "Installing proxy script to ${PROXY_DST}..."

cat > "${PROXY_DST}" << PROXY_EOF
#!/usr/bin/env python3

"""
AWS IMDS MITM Proxy (REMOTE variant)

Runs on a dedicated proxy host. Client instances reach it directly via
AWS_EC2_METADATA_SERVICE_ENDPOINT=http://<this-host-ip>:${LISTEN_PORT}.

No iptables redirect is used; the proxy listens on a TCP port and forwards
to the local IMDS at 169.254.169.254:80.

Performs three categories of rewriting on responses:

1. REQUEST rewriting (faux -> commercial):
   If a request contains a classified-partition domain (sc2s.sgov.gov /
   c2s.ic.gov), rewrite it to the commercial amazonaws.com equivalent
   before forwarding to the real IMDS backend.

2. RESPONSE rewriting (commercial -> faux), applied unconditionally:
   a. Domain rewriting:    FQDNs like service.us-east-1.amazonaws.com ->
                           service.us-isob-east-1.sc2s.sgov.gov
   b. Region rewriting:    commercial region/AZ strings -> faux equivalents
   c. Partition rewriting: bare TLD ('amazonaws.com') and partition name
                           ('aws') values returned by endpoints like
                           /latest/meta-data/services/domain and
                           /latest/meta-data/services/partition.

Supports:
  - AWS Secret Region     (sc2s.sgov.gov  / us-isob-east-1 / aws-iso-b)
  - AWS Top Secret East   (c2s.ic.gov     / us-iso-east-1  / aws-iso)
  - AWS Top Secret West   (c2s.ic.gov     / us-iso-west-1  / aws-iso)
"""

import socket
import threading
import sys
import os
import re as _re
from datetime import datetime
from urllib.parse import unquote, quote

# =============================================================================
# Configuration
# =============================================================================
LISTEN_ADDR   = "${LISTEN_ADDR}"
LISTEN_PORT   = ${LISTEN_PORT}
IMDS_ENDPOINT = "169.254.169.254"
IMDS_PORT     = 80
LOG_FILE      = "/var/log/imds-proxy.log"

PROXY_EOF

# =============================================================================
# Append the rest of the proxy script (literal heredoc - no shell expansion)
# =============================================================================
cat >> "${PROXY_DST}" << 'PROXY_EOF'

# =============================================================================
# Partition / region definitions
# =============================================================================
SC2S_TLD        = "sc2s.sgov.gov"
SC2S_REGION     = "us-isob-east-1"
SC2S_PARTITION  = "aws-iso-b"
C2S_TLD         = "c2s.ic.gov"
C2S_REGION_EAST = "us-iso-east-1"
C2S_REGION_WEST = "us-iso-west-1"
C2S_PARTITION   = "aws-iso"
REAL_TLD        = "amazonaws.com"
REAL_PARTITION  = "aws"

FAUX_DOMAIN_MARKERS = [SC2S_TLD, C2S_TLD]

PROXY_EOF

cat >> "${PROXY_DST}" << PROXY_EOF
# =============================================================================
# Region / AZ rewrite map (commercial -> faux)
# Configured at install time via --<commercial-region>=<faux-region> args.
# =============================================================================
REGION_MAP = ${REGION_MAP_PYTHON}
PROXY_EOF

cat >> "${PROXY_DST}" << 'PROXY_EOF'

# =============================================================================
# Partition / TLD rewrite map (commercial -> faux)
# Applied unconditionally to all IMDS response bodies AFTER domain and region
# rewriting (order matters - see comments in handle_client).
#
# These catch endpoints that return bare partition values, e.g.
#   /latest/meta-data/services/domain     -> "amazonaws.com"
#   /latest/meta-data/services/partition  -> "aws"
# and the ARN partition embedded in iam/info and iam/security-credentials/<role>.
#
# Keep aligned with REGION_MAP - same target partition each time.
# =============================================================================
PARTITION_TLD_MAP = {
    REAL_TLD: C2S_TLD,        # -> sc2s.sgov.gov   (Secret)
    # REAL_TLD: C2S_TLD,       # -> c2s.ic.gov      (TS East/West)
}

# Anchor the partition-name rewrite to ARN context only, so we do NOT
# accidentally mangle the bare substring "aws" wherever else it appears
# (hostnames, comments, JSON keys, etc.). The ARN form is the only place
# the partition name appears as a token inside IMDS responses.
PARTITION_NAME_ARN_MAP = {
    f"arn:{REAL_PARTITION}:": f"arn:{SC2S_PARTITION}:",        # Secret
    # f"arn:{REAL_PARTITION}:": f"arn:{C2S_PARTITION}:",       # Top Secret
}

# =============================================================================
# Domain map builder
# =============================================================================
def _entries(prefix, fips_prefix=None):
    entries = {}
    for region, tld in [
        (SC2S_REGION,     SC2S_TLD),
        (C2S_REGION_EAST, C2S_TLD),
        (C2S_REGION_WEST, C2S_TLD),
    ]:
        entries[f"{prefix}.{region}.{tld}"] = f"{prefix}.{region}.{REAL_TLD}"
        if fips_prefix:
            entries[f"{fips_prefix}.{region}.{tld}"] = f"{fips_prefix}.{region}.{REAL_TLD}"
    return entries

DOMAIN_MAP = {}
DOMAIN_MAP.update(_entries("apigateway"))
DOMAIN_MAP.update(_entries("execute-api"))
DOMAIN_MAP.update(_entries("appconfig", "appconfig-fips"))
DOMAIN_MAP.update(_entries("appconfigdata"))
DOMAIN_MAP.update(_entries("application-autoscaling"))
DOMAIN_MAP[f"athena.{C2S_REGION_EAST}.{C2S_TLD}"] = f"athena.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP[f"aurora-cp.{C2S_REGION_EAST}.{C2S_TLD}"] = f"aurora-cp.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("autoscaling"))
DOMAIN_MAP[f"budgets.global.{SC2S_TLD}"] = "budgets.amazonaws.com"
DOMAIN_MAP.update(_entries("cloudcontrolapi"))
DOMAIN_MAP.update(_entries("cloudformation"))
DOMAIN_MAP.update(_entries("cloudtrail", "cloudtrail-fips"))
DOMAIN_MAP.update(_entries("monitoring"))
DOMAIN_MAP.update(_entries("events"))
DOMAIN_MAP.update(_entries("logs"))
DOMAIN_MAP.update(_entries("synthetics"))
DOMAIN_MAP.update(_entries("oam"))
for _r in [C2S_REGION_EAST, C2S_REGION_WEST]:
    DOMAIN_MAP[f"cloudwatchlogs-vpce.{_r}.{C2S_TLD}"] = f"cloudwatchlogs-vpce.{_r}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("codedeploy"))
DOMAIN_MAP[f"comprehend.{C2S_REGION_EAST}.{C2S_TLD}"] = f"comprehend.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("config", "config-fips"))
DOMAIN_MAP[f"ce.{SC2S_REGION}.{SC2S_TLD}"] = f"ce.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("dlm"))
DOMAIN_MAP[f"datapipeline.{C2S_REGION_EAST}.{C2S_TLD}"]   = f"datapipeline.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP[f"datapipeline-1.{C2S_REGION_EAST}.{C2S_TLD}"] = f"datapipeline-1.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("dms"))
DOMAIN_MAP.update(_entries("directconnect"))
DOMAIN_MAP.update(_entries("ds", "ds-fips"))
DOMAIN_MAP.update(_entries("dynamodb"))
DOMAIN_MAP.update(_entries("streams.dynamodb"))
DOMAIN_MAP[f"streams.dynamodb-fips.{SC2S_REGION}.{SC2S_TLD}"] = f"streams.dynamodb-fips.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("ebs"))
DOMAIN_MAP.update(_entries("ec2"))
DOMAIN_MAP.update(_entries("ec2messages"))
DOMAIN_MAP[f"ec2-pgs.{SC2S_REGION}.{SC2S_TLD}"] = f"ec2-pgs.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"ec2cms.{SC2S_REGION}.{SC2S_TLD}"]  = f"ec2cms.{SC2S_REGION}.{REAL_TLD}"
for _r in [C2S_REGION_EAST, C2S_REGION_WEST]:
    DOMAIN_MAP[f"ec2hostel.{_r}.{C2S_TLD}"]        = f"ec2hostel.{_r}.{REAL_TLD}"
    DOMAIN_MAP[f"ec2launchv2.{_r}.{C2S_TLD}"]      = f"ec2launchv2.{_r}.{REAL_TLD}"
    DOMAIN_MAP[f"ec2-vpce-service.{_r}.{C2S_TLD}"] = f"ec2-vpce-service.{_r}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("ecr"))
DOMAIN_MAP.update(_entries("api.ecr"))
for _r in [C2S_REGION_EAST, C2S_REGION_WEST]:
    DOMAIN_MAP[f"ecr-analytics.{_r}.{C2S_TLD}"] = f"ecr-analytics.{_r}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("ecs"))
for _r in [C2S_REGION_EAST, C2S_REGION_WEST]:
    DOMAIN_MAP[f"ecs-console.{_r}.{C2S_TLD}"] = f"ecs-console.{_r}.{REAL_TLD}"
    DOMAIN_MAP[f"ecs-prtacs.{_r}.{C2S_TLD}"]  = f"ecs-prtacs.{_r}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("elasticfilesystem", "elasticfilesystem-fips"))
DOMAIN_MAP.update(_entries("eks"))
DOMAIN_MAP.update(_entries("elasticache"))
for _r in [C2S_REGION_EAST, C2S_REGION_WEST]:
    DOMAIN_MAP[f"elasticache.console.{_r}.{C2S_TLD}"] = f"elasticache.console.{_r}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("elasticloadbalancing"))
for _r in [C2S_REGION_EAST, C2S_REGION_WEST]:
    DOMAIN_MAP[f"elb-agw.{_r}.{C2S_TLD}"] = f"elb-agw.{_r}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("elasticmapreduce"))
for _r in [C2S_REGION_EAST, C2S_REGION_WEST]:
    DOMAIN_MAP[f"emr-console.{_r}.{C2S_TLD}"] = f"emr-console.{_r}.{REAL_TLD}"
for _r in [C2S_REGION_EAST, C2S_REGION_WEST]:
    DOMAIN_MAP[f"eventbridgeconsole.{_r}.{C2S_TLD}"] = f"eventbridgeconsole.{_r}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("firehose"))
DOMAIN_MAP.update(_entries("kinesis"))
for _r in [C2S_REGION_EAST, C2S_REGION_WEST]:
    DOMAIN_MAP[f"kinesisfirehose-console.{_r}.{C2S_TLD}"] = f"kinesisfirehose-console.{_r}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("glacier"))
DOMAIN_MAP[f"glue.{C2S_REGION_EAST}.{C2S_TLD}"]                  = f"glue.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP[f"glue-crawler.{C2S_REGION_EAST}.{C2S_TLD}"]          = f"glue-crawler.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP[f"datacatalog.{C2S_REGION_EAST}.{C2S_TLD}"]           = f"datacatalog.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP[f"aws-glue-tape-service.{C2S_REGION_EAST}.{C2S_TLD}"] = f"aws-glue-tape-service.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("health"))
DOMAIN_MAP.update(_entries("iam"))
DOMAIN_MAP[f"iam-policyeditor.{SC2S_REGION}.{SC2S_TLD}"] = f"iam-policyeditor.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("imagebuilder"))
DOMAIN_MAP.update(_entries("kms", "kms-fips"))
DOMAIN_MAP.update(_entries("lambda"))
DOMAIN_MAP.update(_entries("license-manager"))
DOMAIN_MAP.update(_entries("medialive", "medialive-fips"))
DOMAIN_MAP.update(_entries("mediapackage"))
DOMAIN_MAP[f"metering.marketplace.{SC2S_REGION}.{SC2S_TLD}"] = f"metering.marketplace.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"marketplace.{C2S_REGION_EAST}.{C2S_TLD}"]       = f"marketplace.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("es"))
DOMAIN_MAP[f"organizations.{SC2S_REGION}.{SC2S_TLD}"]        = f"organizations.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"organizations-widget.{SC2S_REGION}.{SC2S_TLD}"] = f"organizations-widget.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"organizations-policy-delegation-widget.{SC2S_REGION}.{SC2S_TLD}"] = \
    f"organizations-policy-delegation-widget.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("outposts"))
DOMAIN_MAP[f"aws-parallelcluster.{C2S_REGION_EAST}.{C2S_TLD}"] = f"aws-parallelcluster.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("ram", "ram-fips"))
DOMAIN_MAP.update(_entries("rds", "rds-fips"))
DOMAIN_MAP.update(_entries("rbin", "rbin-fips"))
DOMAIN_MAP.update(_entries("redshift", "redshift-fips"))
DOMAIN_MAP.update(_entries("resource-groups"))
DOMAIN_MAP.update(_entries("tagging"))
DOMAIN_MAP[f"route53.{SC2S_TLD}"] = f"route53.{REAL_TLD}"
DOMAIN_MAP[f"route53.{C2S_TLD}"]  = f"route53.{REAL_TLD}"
DOMAIN_MAP.update(_entries("route53resolver"))
DOMAIN_MAP.update(_entries("arc-zonal-shift"))
DOMAIN_MAP.update(_entries("s3"))
DOMAIN_MAP.update(_entries("s3-fips"))
for _region, _tld in [(SC2S_REGION, SC2S_TLD), (C2S_REGION_EAST, C2S_TLD), (C2S_REGION_WEST, C2S_TLD)]:
    DOMAIN_MAP[f".s3.{_region}.{_tld}"]              = f".s3.{_region}.{REAL_TLD}"
    DOMAIN_MAP[f"s3-fips.dualstack.{_region}.{_tld}"] = f"s3-fips.dualstack.{_region}.{REAL_TLD}"
DOMAIN_MAP[f"s3-control.{SC2S_REGION}.{SC2S_TLD}"]                    = f"s3-control.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"s3-control-fips.{SC2S_REGION}.{SC2S_TLD}"]               = f"s3-control-fips.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"s3-control.dualstack.{SC2S_REGION}.{SC2S_TLD}"]          = f"s3-control.dualstack.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"s3-control-fips.dualstack.{SC2S_REGION}.{SC2S_TLD}"]     = f"s3-control-fips.dualstack.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"s3-outposts.{SC2S_REGION}.{SC2S_TLD}"]                   = f"s3-outposts.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"s3-outposts-fips.{SC2S_REGION}.{SC2S_TLD}"]              = f"s3-outposts-fips.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"s3-accesspoint.{SC2S_REGION}.{SC2S_TLD}"]                = f"s3-accesspoint.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"s3-accesspoint-fips.{SC2S_REGION}.{SC2S_TLD}"]           = f"s3-accesspoint-fips.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"s3-accesspoint.dualstack.{SC2S_REGION}.{SC2S_TLD}"]      = f"s3-accesspoint.dualstack.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"s3-accesspoint-fips.dualstack.{SC2S_REGION}.{SC2S_TLD}"] = f"s3-accesspoint-fips.dualstack.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"alas.s3.{SC2S_REGION}.{SC2S_TLD}"]    = f"alas.s3.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"alas.s3.{C2S_REGION_EAST}.{C2S_TLD}"] = f"alas.s3.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("api.sagemaker"))
DOMAIN_MAP.update(_entries("runtime.sagemaker"))
DOMAIN_MAP[f"samurai.{C2S_REGION_EAST}.{C2S_TLD}"]           = f"samurai.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP[f"metrics.sagemaker.{C2S_REGION_EAST}.{C2S_TLD}"] = f"metrics.sagemaker.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("secretsmanager", "secretsmanager-fips"))
DOMAIN_MAP.update(_entries("sns"))
DOMAIN_MAP.update(_entries("sqs"))
DOMAIN_MAP.update(_entries("ssm"))
DOMAIN_MAP.update(_entries("ssmmessages"))
DOMAIN_MAP.update(_entries("states", "states-fips"))
DOMAIN_MAP.update(_entries("sync-states"))
DOMAIN_MAP[f"storagegateway.{SC2S_REGION}.{SC2S_TLD}"]      = f"storagegateway.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP[f"storagegateway-fips.{SC2S_REGION}.{SC2S_TLD}"] = f"storagegateway-fips.{SC2S_REGION}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("sts"))
DOMAIN_MAP.update(_entries("support"))
DOMAIN_MAP.update(_entries("swf", "swf-fips"))
DOMAIN_MAP[f"transcribe.{C2S_REGION_EAST}.{C2S_TLD}"]          = f"transcribe.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP[f"transcribestreaming.{C2S_REGION_EAST}.{C2S_TLD}"] = f"transcribestreaming.{C2S_REGION_EAST}.{REAL_TLD}"
for _r in [C2S_REGION_EAST, C2S_REGION_WEST]:
    DOMAIN_MAP[f"transitgateway.{_r}.{C2S_TLD}"] = f"transitgateway.{_r}.{REAL_TLD}"
DOMAIN_MAP[f"translate.{C2S_REGION_EAST}.{C2S_TLD}"] = f"translate.{C2S_REGION_EAST}.{REAL_TLD}"
DOMAIN_MAP.update(_entries("workspaces", "workspaces-fips"))

_EXACT_MAP  = {k: v for k, v in DOMAIN_MAP.items() if not k.startswith(".")}
_SUFFIX_MAP = {k: v for k, v in DOMAIN_MAP.items() if k.startswith(".")}

# =============================================================================
# Logging
# =============================================================================
def log(message):
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    log_msg = f"[{timestamp}] {message}\n"
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(log_msg)
    except Exception:
        pass
    print(f"[{timestamp}] {message}", file=sys.stderr, flush=True)

# =============================================================================
# Domain rewriting (faux <-> commercial)
# =============================================================================
def rewrite_domains(text, direction):
    if direction == "to_commercial":
        for faux, comm in _EXACT_MAP.items():
            text = text.replace(faux, comm)
            text = text.replace(quote(faux, safe=''), quote(comm, safe=''))
        for faux_sfx, comm_sfx in _SUFFIX_MAP.items():
            text = text.replace(faux_sfx, comm_sfx)
            text = text.replace(quote(faux_sfx, safe=''), quote(comm_sfx, safe=''))
    else:  # to_faux
        for faux, comm in _EXACT_MAP.items():
            text = text.replace(comm, faux)
            text = text.replace(quote(comm, safe=''), quote(faux, safe=''))
        for comm_sfx, faux_sfx in {v: k for k, v in _SUFFIX_MAP.items()}.items():
            text = text.replace(comm_sfx, faux_sfx)
            text = text.replace(quote(comm_sfx, safe=''), quote(faux_sfx, safe=''))
    return text

# =============================================================================
# Region / AZ rewriting (commercial -> faux), unconditional on all responses
# =============================================================================
def rewrite_regions(text, direction):
    if direction == "to_faux":
        for comm, faux in REGION_MAP.items():
            for az_suffix in ["a", "b", "c", "d"]:
                text = text.replace(f"{comm}{az_suffix}", f"{faux}{az_suffix}")
            text = text.replace(comm, faux)
    else:  # to_commercial
        for comm, faux in REGION_MAP.items():
            for az_suffix in ["a", "b", "c", "d"]:
                text = text.replace(f"{faux}{az_suffix}", f"{comm}{az_suffix}")
            text = text.replace(faux, comm)
    return text

# =============================================================================
# Partition rewriting (commercial -> faux), unconditional on all responses.
# Catches:
#   - bare TLD ('amazonaws.com') for /latest/meta-data/services/domain
#   - partition name ('aws') ONLY when it appears as 'arn:aws:' to avoid
#     mangling the substring 'aws' wherever else it might appear
# Run AFTER rewrite_domains so we don't strip 'amazonaws.com' off the end of
# FQDNs before the domain map gets a chance to match them.
# =============================================================================
def rewrite_partition(text, direction):
    if direction == "to_faux":
        for comm_arn, faux_arn in PARTITION_NAME_ARN_MAP.items():
            text = text.replace(comm_arn, faux_arn)
        for comm_tld, faux_tld in PARTITION_TLD_MAP.items():
            text = text.replace(comm_tld, faux_tld)
    else:  # to_commercial
        for comm_arn, faux_arn in PARTITION_NAME_ARN_MAP.items():
            text = text.replace(faux_arn, comm_arn)
        for comm_tld, faux_tld in PARTITION_TLD_MAP.items():
            text = text.replace(faux_tld, comm_tld)
    return text

# =============================================================================
# IMDSv2 header detection
# =============================================================================
IMDSV2_HEADERS = [
    "x-aws-ec2-metadata-token",
    "x-aws-ec2-metadata-token-ttl-seconds",
]

def contains_imdsv2_headers(text):
    lower = text.lower()
    return any(h in lower for h in IMDSV2_HEADERS)

# =============================================================================
# Client handler
# =============================================================================
def handle_client(client_socket, client_address):
    imds_socket = None
    try:
        request_data = b''
        client_socket.settimeout(5)
        while True:
            try:
                chunk = client_socket.recv(4096)
                if not chunk:
                    break
                request_data += chunk
                if b'\r\n\r\n' in request_data or b'\n\n' in request_data:
                    headers_end = request_data.find(b'\r\n\r\n')
                    if headers_end == -1:
                        headers_end = request_data.find(b'\n\n')
                        delim_len = 2
                    else:
                        delim_len = 4
                    headers_str = request_data[:headers_end].decode('utf-8', errors='replace')
                    content_length = 0
                    for line in headers_str.split('\n'):
                        if line.lower().startswith('content-length:'):
                            content_length = int(line.split(':')[1].strip())
                            break
                    if len(request_data) >= headers_end + delim_len + content_length:
                        break
            except socket.timeout:
                break

        if not request_data:
            log(f"No data received from {client_address}")
            return

        log(f"Request from {client_address}: {len(request_data)} bytes")
        request_str = request_data.decode('utf-8', errors='replace')
        first_line  = request_str.split('\n')[0] if '\n' in request_str else request_str
        log(f"Request first line: {first_line.strip()}")

        # Request rewriting: faux -> commercial (only if faux markers present)
        decoded_request = unquote(request_str)
        needs_rewrite = any(
            m in request_str or m in decoded_request
            for m in FAUX_DOMAIN_MARKERS
        )
        if needs_rewrite:
            detected = next(m for m in FAUX_DOMAIN_MARKERS
                            if m in request_str or m in decoded_request)
            log(f"Detected faux domain ({detected}) - rewriting request")
            original_request = request_str
            request_str  = rewrite_domains(request_str, "to_commercial")
            request_data = request_str.encode('utf-8')
            rewritten_first_line = request_str.split('\n')[0] if '\n' in request_str else request_str
            log(f"Rewritten first line: {rewritten_first_line.strip()}")
            if original_request == request_str:
                log("WARNING: Request unchanged after rewrite - check DOMAIN_MAP")
        else:
            log("No faux domain detected - passing request through unchanged")

        if contains_imdsv2_headers(request_str):
            log("IMDSv2 token headers present - passing through untouched")

        # Forward to local IMDS. No SO_MARK needed since there is no iptables
        # redirect on this host.
        imds_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        imds_socket.settimeout(10)
        imds_socket.connect((IMDS_ENDPOINT, IMDS_PORT))
        imds_socket.sendall(request_data)

        response_data = b''
        imds_socket.settimeout(5)
        while True:
            try:
                chunk = imds_socket.recv(4096)
                if not chunk:
                    break
                response_data += chunk
            except socket.timeout:
                break

        log(f"Response from IMDS: {len(response_data)} bytes")

        # Response rewriting: commercial -> faux (unconditional).
        # Order matters:
        #   1. rewrite_domains     - matches FQDNs in DOMAIN_MAP
        #   2. rewrite_regions     - replaces region/AZ strings
        #   3. rewrite_partition   - replaces bare TLD and ARN partition name
        #
        # rewrite_partition MUST come last. If it ran first, it would strip
        # 'amazonaws.com' off the end of FQDNs and rewrite_domains would no
        # longer find any matches in DOMAIN_MAP.
        response_str = response_data.decode('utf-8', errors='replace')
        if '\r\n\r\n' in response_str:
            resp_headers, resp_body = response_str.split('\r\n\r\n', 1)
            delimiter = '\r\n\r\n'
        elif '\n\n' in response_str:
            resp_headers, resp_body = response_str.split('\n\n', 1)
            delimiter = '\n\n'
        else:
            resp_headers, resp_body, delimiter = response_str, '', '\r\n\r\n'

        rewritten_body = rewrite_domains(resp_body,        "to_faux")
        rewritten_body = rewrite_regions(rewritten_body,   "to_faux")
        rewritten_body = rewrite_partition(rewritten_body, "to_faux")

        if rewritten_body != resp_body:
            log("Response body rewritten (commercial -> faux domains/regions/partition)")
            new_body_bytes = rewritten_body.encode('utf-8')
            resp_headers = _re.sub(
                r'(?i)(content-length:\s*)\d+',
                lambda m: m.group(1) + str(len(new_body_bytes)),
                resp_headers
            )
        else:
            log("Response body unchanged (no commercial domains, regions, or partition values found)")
            new_body_bytes = resp_body.encode('utf-8')

        response_data = (
            resp_headers.encode('utf-8') +
            delimiter.encode('utf-8') +
            new_body_bytes
        )
        client_socket.sendall(response_data)
        log(f"Response sent to {client_address}")

    except Exception as e:
        log(f"ERROR handling {client_address}: {e}")
        import traceback
        log(traceback.format_exc())
    finally:
        try:
            if imds_socket:
                imds_socket.close()
        except Exception:
            pass
        try:
            client_socket.close()
        except Exception:
            pass

# =============================================================================
# Main
# =============================================================================
def main():
    if os.geteuid() != 0:
        log("ERROR: Must be run as root")
        sys.exit(1)

    log(f"Starting AWS IMDS MITM Proxy (REMOTE variant)")
    log(f"Listening on {LISTEN_ADDR}:{LISTEN_PORT}")
    log(f"Forwarding to {IMDS_ENDPOINT}:{IMDS_PORT}")
    log(f"Faux domain markers: {FAUX_DOMAIN_MARKERS}")
    log(f"DOMAIN_MAP entries loaded: {len(DOMAIN_MAP)}")
    log(f"REGION_MAP: {REGION_MAP}")
    log(f"PARTITION_TLD_MAP: {PARTITION_TLD_MAP}")
    log(f"PARTITION_NAME_ARN_MAP: {PARTITION_NAME_ARN_MAP}")
    log("NOTE: No iptables redirect is in use. Clients must reach this host")
    log("      via AWS_EC2_METADATA_SERVICE_ENDPOINT=http://<host>:<port>")

    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind((LISTEN_ADDR, LISTEN_PORT))
    server_socket.listen(64)
    log(f"Listening on {LISTEN_ADDR}:{LISTEN_PORT}")

    try:
        while True:
            client_socket, client_address = server_socket.accept()
            log(f"Connection from {client_address}")
            threading.Thread(
                target=handle_client,
                args=(client_socket, client_address),
                daemon=True
            ).start()
    except KeyboardInterrupt:
        log("Shutting down proxy...")
    finally:
        server_socket.close()

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"FATAL ERROR: {e}")
        import traceback
        log(traceback.format_exc())
        sys.exit(1)
PROXY_EOF

chmod 755 "${PROXY_DST}"
ok "Proxy script installed"

# =============================================================================
# Create log file
# =============================================================================
touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"
ok "Log file ready: ${LOG_FILE}"

# =============================================================================
# Install systemd service
# =============================================================================
info "Installing systemd service..."
cat > "${SERVICE_FILE}" <<SERVICE
[Unit]
Description=AWS IMDS MITM Proxy (Remote variant)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${PROXY_DST}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
User=root
Group=root

[Install]
WantedBy=multi-user.target
SERVICE

ok "Service file written: ${SERVICE_FILE}"

# =============================================================================
# Enable and start service
# =============================================================================
info "Reloading systemd daemon..."
systemctl daemon-reload

info "Enabling ${SERVICE_NAME} service..."
systemctl enable "${SERVICE_NAME}"
ok "Service enabled"

info "Starting ${SERVICE_NAME} service..."
systemctl start "${SERVICE_NAME}"
sleep 2

# =============================================================================
# Verify service
# =============================================================================
info "Verifying service status..."
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "Service is active"
else
    error "Service failed to start — check: journalctl -u ${SERVICE_NAME} -n 50"
fi

# =============================================================================
# Verify listening port
# =============================================================================
info "Verifying proxy is listening on ${LISTEN_ADDR}:${LISTEN_PORT}..."
sleep 1
if command -v ss >/dev/null 2>&1; then
    LISTEN_OUT=$(ss -tlnp 2>/dev/null | grep ":${LISTEN_PORT} " || true)
elif command -v netstat >/dev/null 2>&1; then
    LISTEN_OUT=$(netstat -tlnp 2>/dev/null | grep ":${LISTEN_PORT} " || true)
else
    LISTEN_OUT=""
fi

if [[ -n "${LISTEN_OUT}" ]]; then
    ok "Proxy is listening:"
    echo "    ${LISTEN_OUT}"
else
    warn "Could not confirm listener on port ${LISTEN_PORT} — check: journalctl -u ${SERVICE_NAME} -n 50"
fi

# =============================================================================
# Smoke test (against the proxy directly, not 169.254.169.254)
# =============================================================================
info "Running smoke test against proxy on 127.0.0.1:${LISTEN_PORT}..."

TOKEN=$(curl -s --max-time 5 -X PUT "http://127.0.0.1:${LISTEN_PORT}/latest/api/token" \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' 2>/dev/null || true)

if [[ -z "${TOKEN}" ]]; then
    warn "Could not obtain IMDSv2 token via the proxy — check logs"
    warn "  journalctl -u ${SERVICE_NAME} -n 50"
    warn "  tail -n 50 ${LOG_FILE}"
else
    ok "IMDSv2 token obtained via proxy"

    REGION_RESP=$(curl -s --max-time 5 \
        "http://127.0.0.1:${LISTEN_PORT}/latest/meta-data/placement/region" \
        -H "X-aws-ec2-metadata-token: ${TOKEN}" 2>/dev/null || true)

    FAUX_REGIONS=("us-isob-east-1" "us-iso-east-1" "us-iso-west-1")
    REGION_OK=false
    for r in "${FAUX_REGIONS[@]}"; do
        [[ "${REGION_RESP}" == "${r}" ]] && REGION_OK=true && break
    done

    if [[ "${REGION_OK}" == "true" ]]; then
        ok "Region rewrite confirmed: ${REGION_RESP}"
    else
        warn "Region rewrite not confirmed — got '${REGION_RESP}'"
        warn "Check REGION_MAP in ${PROXY_DST} and restart the service"
    fi

    DOMAIN_RESP=$(curl -s --max-time 5 \
        "http://127.0.0.1:${LISTEN_PORT}/latest/meta-data/services/domain" \
        -H "X-aws-ec2-metadata-token: ${TOKEN}" 2>/dev/null || true)

    FAUX_TLDS=("sc2s.sgov.gov" "c2s.ic.gov")
    DOMAIN_OK=false
    for t in "${FAUX_TLDS[@]}"; do
        [[ "${DOMAIN_RESP}" == "${t}" ]] && DOMAIN_OK=true && break
    done

    if [[ "${DOMAIN_OK}" == "true" ]]; then
        ok "TLD rewrite confirmed: ${DOMAIN_RESP}"
    else
        warn "TLD rewrite not confirmed — got '${DOMAIN_RESP}'"
        warn "Check PARTITION_TLD_MAP in ${PROXY_DST} and restart the service"
    fi

    PARTITION_RESP=$(curl -s --max-time 5 \
        "http://127.0.0.1:${LISTEN_PORT}/latest/meta-data/services/partition" \
        -H "X-aws-ec2-metadata-token: ${TOKEN}" 2>/dev/null || true)

    if [[ -n "${PARTITION_RESP}" ]]; then
        # /services/partition returns the bare partition name. We currently
        # only rewrite 'aws' inside ARN context, so the bare value at this
        # endpoint will still read 'aws'. Surface this so the operator knows.
        if [[ "${PARTITION_RESP}" == "aws-iso-b" || "${PARTITION_RESP}" == "aws-iso" ]]; then
            ok "Partition rewrite confirmed: ${PARTITION_RESP}"
        else
            warn "Partition value at /services/partition is '${PARTITION_RESP}' (bare 'aws' is left unchanged)"
            warn "ARN partitions in iam/info are still rewritten via PARTITION_NAME_ARN_MAP"
            warn "If your clients read /services/partition directly, extend rewrite_partition()"
        fi
    fi
fi

# =============================================================================
# Detect this host's primary private IP (best-effort, for the user's reference)
# =============================================================================
PRIVATE_IP=""
if command -v ip >/dev/null 2>&1; then
    PRIVATE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
fi

# =============================================================================
# Done
# =============================================================================
echo ""
info "===== Installation complete (REMOTE variant) ====="
echo ""
echo "  Proxy script  : ${PROXY_DST}"
echo "  Service       : ${SERVICE_NAME}"
echo "  Log file      : ${LOG_FILE}"
echo "  Listening on  : ${LISTEN_ADDR}:${LISTEN_PORT}"
echo ""
echo "  Client-side configuration (on each instance that should use this proxy):"
if [[ -n "${PRIVATE_IP}" ]]; then
    echo "    export AWS_EC2_METADATA_SERVICE_ENDPOINT=http://${PRIVATE_IP}:${LISTEN_PORT}"
else
    echo "    export AWS_EC2_METADATA_SERVICE_ENDPOINT=http://<this-host-private-ip>:${LISTEN_PORT}"
fi
echo ""
echo "  IMPORTANT — security:"
echo "    * Restrict TCP/${LISTEN_PORT} via the security group to the client"
echo "      instances that should share this host's IAM role. Anyone able to"
echo "      reach this port can mint IMDSv2 credentials for this host's role."
echo "    * CloudTrail will attribute all client API calls to THIS host's"
echo "      role and instance ID."
echo ""
echo "  Useful commands:"
echo "    sudo systemctl status ${SERVICE_NAME}"
echo "    sudo journalctl -u ${SERVICE_NAME} -f"
echo "    sudo systemctl restart ${SERVICE_NAME}"
echo "    sudo tail -f ${LOG_FILE}"
echo ""