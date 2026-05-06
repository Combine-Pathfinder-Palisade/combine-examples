# Combine AWS IMDS Proxy (Remote variant)

> **Status: EXPERIMENTAL.** Please report bugs to the Combine team at
> service-request@sequoiainc.com.

A self-contained installer for the Combine AWS IMDS proxy. This **remote**
variant runs on a single dedicated host that serves IMDS responses to *other*
EC2 instances over the VPC. It rewrites IMDS request/response traffic so that
clients running in commercial AWS see metadata that looks like it came from a
classified-partition region (SC2S, C2S East, or C2S West).

For the in-host (local-redirect) variant that uses `iptables` to capture
`169.254.169.254` traffic on the same instance, see `imds-proxy.sh`.

---

## What it does

The proxy sits between EC2 IMDS clients and the real `169.254.169.254`
endpoint and performs three categories of rewriting:

1. **Request rewriting (emulated -> commercial).** If a request contains a
   classified-partition domain (`sc2s.sgov.gov` / `c2s.ic.gov`), it is
   rewritten to the commercial `amazonaws.com` equivalent before being
   forwarded to the real IMDS backend.
2. **Response rewriting (commercial -> emulated), applied unconditionally:**
   - **Domain rewriting** — FQDNs like `service.us-east-1.amazonaws.com`
     become `service.us-isob-east-1.sc2s.sgov.gov`.
   - **Region rewriting** — commercial region/AZ strings are replaced with
     their emulated equivalents.
   - **Partition rewriting** — the bare TLD (`amazonaws.com`) and ARN
     partition name (`aws`) returned by endpoints like
     `/latest/meta-data/services/domain`,
     `/latest/meta-data/services/partition`, and the ARN embedded in
     `iam/info` and `iam/security-credentials/<role>` are rewritten.

### Supported emulated partitions

| Symbolic name      | Region            | TLD              | Partition   |
| ------------------ | ----------------- | ---------------- | ----------- |
| `SC2S_REGION`      | `us-isob-east-1`  | `sc2s.sgov.gov`  | `aws-iso-b` |
| `C2S_REGION_EAST`  | `us-iso-east-1`   | `c2s.ic.gov`     | `aws-iso`   |
| `C2S_REGION_WEST`  | `us-iso-west-1`   | `c2s.ic.gov`     | `aws-iso`   |

---

## Differences from the local variant

| Concern                  | Local (`imds-proxy.sh`)                  | Remote (this script)                          |
| ------------------------ | ---------------------------------------- | --------------------------------------------- |
| Traffic capture          | `iptables` NAT redirect of `169.254/32`  | Clients connect directly to `<host>:8090`     |
| `SO_MARK` / fwmark logic | Required to avoid redirect loop          | Not used                                      |
| Listen address           | `127.0.0.1` only                         | Configurable, default `0.0.0.0`               |
| Smoke test target        | `169.254.169.254`                        | The proxy's own listen port                   |
| Reinstall behavior       | Idempotent                               | Clean reinstall every run                     |

The remote variant is intended for a fleet model where one IAM-bearing host
fronts IMDS for several IAM-less clients sharing its role. Each client is
pointed at the proxy via `AWS_EC2_METADATA_SERVICE_ENDPOINT`.

---

## Security warning

**Any host that can reach `LISTEN_ADDR:LISTEN_PORT` can obtain IMDSv2
credentials for the proxy host's IAM role.**

- Restrict access via security groups / NACLs to only the client instances
  that should share this role.
- CloudTrail will attribute **all** client API calls to the proxy host's
  role and instance ID. There is no per-client attribution.
- Do not bind the listener to a public interface unless you fully understand
  the consequences. `0.0.0.0` is the default for convenience inside private
  VPC subnets; tighten it (e.g. to a specific private IP) where possible.

---

## Requirements

- Linux with `systemd` and `python3` (the script will attempt to install
  `python3` via `yum` or `apt-get` if missing)
- Run as root
- Reachable from clients on the configured listen port (default `8090`)
- The host itself must have working IMDS access to `169.254.169.254` and an
  IAM role attached

---
y
## Usage

```bash
sudo bash imds-proxy-remote.sh [--<commercial-region>=<emulated-region> ...]
```

emulated region values may be supplied either by symbolic name or by literal
region string.

### Examples

```bash
# Default: rewrite us-east-1 -> us-isob-east-1 (Secret)
sudo bash imds-proxy-remote.sh

# Single mapping using a symbolic name
sudo bash imds-proxy-remote.sh --us-east-1=SC2S_REGION

# Multiple mappings, mixing names and literal regions
sudo bash imds-proxy-remote.sh \
    --us-east-1=C2S_REGION_EAST \
    --us-west-2=C2S_REGION_WEST
```

### Environment overrides

| Variable      | Default     | Purpose                                       |
| ------------- | ----------- | --------------------------------------------- |
| `LISTEN_ADDR` | `0.0.0.0`   | Bind address. Set to a specific private IP to restrict to one NIC. |
| `LISTEN_PORT` | `8090`      | TCP port the proxy listens on.                |

```bash
sudo LISTEN_ADDR=10.0.1.42 LISTEN_PORT=8090 bash imds-proxy-remote.sh
```

---

## Client-side configuration

On each instance that should route IMDS traffic through the proxy:

```bash
export AWS_EC2_METADATA_SERVICE_ENDPOINT=http://<proxy-host-private-ip>:8090
```

The installer prints the proxy host's primary private IP at the end of a
successful run.

---

## What the installer does

1. **Preflight** — verifies root, `python3`, and `systemd`.
2. **Clean reinstall** — stops, disables, and removes any prior `imds-proxy`
   service and script. Also clears any leftover `iptables` NAT rules from a
   prior local-variant install.
3. **Writes the proxy** to `/usr/local/bin/imds-proxy.py` with the configured
   `LISTEN_ADDR`, `LISTEN_PORT`, and `REGION_MAP` baked in.
4. **Installs and starts** the `imds-proxy` systemd unit
   (`/etc/systemd/system/imds-proxy.service`).
5. **Smoke tests** the proxy by:
   - fetching an IMDSv2 token through it,
   - reading `/latest/meta-data/placement/region` and confirming a emulated
     region is returned,
   - reading `/latest/meta-data/services/domain` and confirming a emulated TLD
     is returned,
   - reading `/latest/meta-data/services/partition` and surfacing whether
     the bare partition value was rewritten.

---

## Files installed

| Path                                      | Purpose                       |
| ----------------------------------------- | ----------------------------- |
| `/usr/local/bin/imds-proxy.py`            | The Python proxy itself       |
| `/etc/systemd/system/imds-proxy.service`  | systemd unit                  |
| `/var/log/imds-proxy.log`                 | Per-request log               |

---

## Operations

```bash
# Service status / logs
sudo systemctl status imds-proxy
sudo journalctl -u imds-proxy -f

# Restart after a config change
sudo systemctl restart imds-proxy

# Tail the proxy's own request log
sudo tail -f /var/log/imds-proxy.log
```

To uninstall, simply re-run the installer (it performs a clean reinstall) or
manually:

```bash
sudo systemctl stop imds-proxy
sudo systemctl disable imds-proxy
sudo rm -f /etc/systemd/system/imds-proxy.service /usr/local/bin/imds-proxy.py
sudo systemctl daemon-reload
```

---

## Troubleshooting

- **Smoke test fails to obtain a token** — check
  `journalctl -u imds-proxy -n 50` and `tail -n 50 /var/log/imds-proxy.log`.
  The most common cause is the host itself not having IMDS access or no IAM
  role attached.
- **Region rewrite not confirmed** — the `--<commercial-region>=<emulated-region>`
  argument did not include the region the host actually runs in. Re-run with
  the correct mapping.
- **TLD rewrite not confirmed** — verify `PARTITION_TLD_MAP` in the installed
  `/usr/local/bin/imds-proxy.py` matches the emulated partition you want.
- **`/services/partition` returns `aws`** — by design. The bare partition
  name is only rewritten inside ARN context (`arn:aws:`) to avoid mangling
  the substring `aws` wherever else it might appear. If your clients read
  `/services/partition` directly and need a emulated value, extend
  `rewrite_partition()` in the proxy.
- **Clients can't reach the proxy** — check the security group on the proxy
  host allows inbound TCP on `LISTEN_PORT` from the client subnet.
