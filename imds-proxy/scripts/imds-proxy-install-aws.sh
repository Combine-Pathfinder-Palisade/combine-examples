#!/bin/bash
##############################################################################
# imds-proxy-install-aws.sh
# Self-contained installer for the AWS IMDS MITM Proxy.
# The proxy Python script is embedded directly in this file.
#
# Installs the proxy to /usr/local/bin/imds-proxy.py, creates a systemd
# service, and verifies the installation with a smoke test.
#
# Usage: sudo bash imds-proxy-install-aws.sh
##############################################################################

set -euo pipefail

PROXY_DST="/usr/local/bin/imds-proxy.py"
SERVICE_NAME="imds-proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="/var/log/imds-proxy.log"

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

command -v iptables  >/dev/null 2>&1 || error "iptables not found on this system."
command -v systemctl >/dev/null 2>&1 || error "systemd not found on this system."

ok "Preflight checks passed"

# =============================================================================
# Stop existing service if running
# =============================================================================
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    info "Stopping existing ${SERVICE_NAME} service..."
    systemctl stop "${SERVICE_NAME}"
    ok "Service stopped"
fi
if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
fi

# =============================================================================
# Write proxy script
# =============================================================================
info "Installing proxy script to ${PROXY_DST}..."

cat > "${PROXY_DST}" << 'PROXY_EOF'
#!/usr/bin/env python3

"""
AWS IMDS MITM Proxy
Intercepts IMDS requests and performs two categories of rewriting:

1. REQUEST rewriting (faux -> commercial):
   If a request contains a classified-partition domain (sc2s.sgov.gov /
   c2s.ic.gov), rewrite it to the commercial amazonaws.com equivalent before
   forwarding to the real IMDS backend.

2. RESPONSE rewriting (commercial -> faux), applied unconditionally:
   a. Domain rewriting: amazonaws.com references -> classified TLD equivalents
   b. Region rewriting: commercial region/AZ strings -> classified region/AZ strings
      This is required because the real IMDS always returns commercial region
      values (e.g. "us-east-1") regardless of request content. Applications
      inside the classified VPC must receive the faux region so they construct
      requests against the correct classified endpoints.

Supports:
  - AWS Secret Region     (sc2s.sgov.gov  / us-isob-east-1)
  - AWS Top Secret East   (c2s.ic.gov     / us-iso-east-1)
  - AWS Top Secret West   (c2s.ic.gov     / us-iso-west-1)
"""

import socket
import threading
import sys
import os
import subprocess
import re as _re
from datetime import datetime
from urllib.parse import unquote, quote

# =============================================================================
# Configuration
# =============================================================================
PROXY_PORT    = 8090
IMDS_ENDPOINT = "169.254.169.254"
IMDS_PORT     = 80
LOG_FILE      = "/var/log/imds-proxy.log"
PROXY_MARK    = 100

# =============================================================================
# Partition / region definitions
# =============================================================================
SC2S_TLD        = "sc2s.sgov.gov"
SC2S_REGION     = "us-isob-east-1"
C2S_TLD         = "c2s.ic.gov"
C2S_REGION_EAST = "us-iso-east-1"
C2S_REGION_WEST = "us-iso-west-1"
REAL_TLD        = "amazonaws.com"

FAUX_DOMAIN_MARKERS = [SC2S_TLD, C2S_TLD]

# =============================================================================
# Region / AZ rewrite map (commercial -> faux)
# Applied unconditionally to all IMDS response bodies.
# Only one target faux region active at a time; comment/uncomment as needed.
# =============================================================================
REGION_MAP = {
    "us-east-1": SC2S_REGION,        # -> us-isob-east-1  (Secret)
    # "us-east-1": C2S_REGION_EAST,  # -> us-iso-east-1   (TS East)
    # "us-west-2": C2S_REGION_WEST,  # -> us-iso-west-1   (TS West)
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
# iptables management
# =============================================================================
def _rule_exists(rule_fragment):
    """Return True if a matching rule already exists in iptables nat OUTPUT."""
    result = subprocess.run(
        f"iptables -t nat -C {rule_fragment}",
        shell=True, capture_output=True
    )
    return result.returncode == 0

def setup_iptables():
    log("Setting up iptables redirect...")

    fwmark_rule = (
        f"OUTPUT -p tcp -d 169.254.169.254 --dport 80 "
        f"-m mark --mark {PROXY_MARK} -j RETURN"
    )
    redirect_rule = (
        f"OUTPUT -p tcp -d 169.254.169.254 --dport 80 "
        f"-j REDIRECT --to-port {PROXY_PORT}"
    )

    # Insert fwmark exemption rule first (must precede the REDIRECT rule)
    if _rule_exists(fwmark_rule):
        log("fwmark exemption rule already present - skipping")
    else:
        result = subprocess.run(
            f"iptables -t nat -I {fwmark_rule}",
            shell=True, capture_output=True, text=True
        )
        log(f"{'OK' if result.returncode == 0 else 'ERROR'} fwmark exemption rule: {result.stderr or 'ok'}")

    # Append REDIRECT rule after
    if _rule_exists(redirect_rule):
        log("REDIRECT rule already present - skipping")
    else:
        result = subprocess.run(
            f"iptables -t nat -A {redirect_rule}",
            shell=True, capture_output=True, text=True
        )
        log(f"{'OK' if result.returncode == 0 else 'ERROR'} REDIRECT rule: {result.stderr or 'ok'}")

    result = subprocess.run(
        "iptables -t nat -L OUTPUT -n -v --line-numbers",
        shell=True, capture_output=True, text=True
    )
    log(f"Current iptables OUTPUT rules:\n{result.stdout}")

def cleanup_iptables():
    log("Cleaning up iptables redirect...")
    for rule in [
        f"OUTPUT -p tcp -d 169.254.169.254 --dport 80 -m mark --mark {PROXY_MARK} -j RETURN",
        f"OUTPUT -p tcp -d 169.254.169.254 --dport 80 -j REDIRECT --to-port {PROXY_PORT}",
    ]:
        result = subprocess.run(
            f"iptables -t nat -D {rule}",
            shell=True, capture_output=True, text=True
        )
        if result.returncode == 0:
            log(f"Removed rule: {rule}")
        else:
            log(f"Rule not found during cleanup (ok): {rule}")

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

        # Forward to IMDS
        imds_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            imds_socket.setsockopt(socket.SOL_SOCKET, 36, PROXY_MARK)
        except Exception as e:
            log(f"Warning: Could not set SO_MARK: {e}")
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

        # Response rewriting: commercial -> faux (unconditional)
        response_str = response_data.decode('utf-8', errors='replace')
        if '\r\n\r\n' in response_str:
            resp_headers, resp_body = response_str.split('\r\n\r\n', 1)
            delimiter = '\r\n\r\n'
        elif '\n\n' in response_str:
            resp_headers, resp_body = response_str.split('\n\n', 1)
            delimiter = '\n\n'
        else:
            resp_headers, resp_body, delimiter = response_str, '', '\r\n\r\n'

        rewritten_body = rewrite_domains(resp_body, "to_faux")
        rewritten_body = rewrite_regions(rewritten_body, "to_faux")

        if rewritten_body != resp_body:
            log("Response body rewritten (commercial -> faux domains/regions)")
            new_body_bytes = rewritten_body.encode('utf-8')
            resp_headers = _re.sub(
                r'(?i)(content-length:\s*)\d+',
                lambda m: m.group(1) + str(len(new_body_bytes)),
                resp_headers
            )
        else:
            log("Response body unchanged (no commercial domains or regions found)")
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

    setup_iptables()

    log(f"Starting AWS IMDS MITM Proxy on port {PROXY_PORT}")
    log(f"Forwarding to {IMDS_ENDPOINT}:{IMDS_PORT}")
    log(f"Using fwmark {PROXY_MARK} for proxy traffic exemption")
    log(f"Faux domain markers: {FAUX_DOMAIN_MARKERS}")
    log(f"DOMAIN_MAP entries loaded: {len(DOMAIN_MAP)}")
    log(f"REGION_MAP: {REGION_MAP}")

    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind(('0.0.0.0', PROXY_PORT))
    server_socket.listen(10)
    log(f"Listening on 0.0.0.0:{PROXY_PORT}")

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
        cleanup_iptables()

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"FATAL ERROR: {e}")
        import traceback
        log(traceback.format_exc())
        cleanup_iptables()
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
Description=AWS IMDS MITM Proxy
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
# Verify iptables
# =============================================================================
info "Verifying iptables rules..."
IPTABLES_OUT=$(iptables -t nat -L OUTPUT -n -v 2>/dev/null)
if echo "${IPTABLES_OUT}" | grep -q "169.254.169.254"; then
    ok "iptables rules present for 169.254.169.254"
else
    warn "iptables rules not detected — check proxy logs"
fi
echo ""
echo "${IPTABLES_OUT}"
echo ""

# =============================================================================
# Smoke test
# =============================================================================
info "Running smoke test..."
TOKEN=$(curl -s --max-time 5 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' 2>/dev/null || true)

if [[ -z "${TOKEN}" ]]; then
    warn "Could not obtain IMDSv2 token — skipping smoke test"
else
    REGION_RESP=$(curl -s --max-time 5 \
        http://169.254.169.254/latest/meta-data/placement/region \
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
fi

# =============================================================================
# Done
# =============================================================================
echo ""
info "===== Installation complete ====="
echo ""
echo "  Proxy script : ${PROXY_DST}"
echo "  Service      : ${SERVICE_NAME}"
echo "  Log file     : ${LOG_FILE}"
echo ""
echo "  Useful commands:"
echo "    sudo systemctl status ${SERVICE_NAME}"
echo "    sudo journalctl -u ${SERVICE_NAME} -f"
echo "    sudo systemctl restart ${SERVICE_NAME}"
echo "    sudo iptables -t nat -L OUTPUT -n -v"
echo ""