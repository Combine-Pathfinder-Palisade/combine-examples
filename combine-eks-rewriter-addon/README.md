# Please note that this webhook is in WIP status.

# combine-eks-rewriter-addon

A small Kubernetes **mutating admission webhook** that extends Combine's emulation **into the
cluster**, so that EKS managed add-ons work in a Combine-emulated (isolated / high-side) region.

---

## The problem it solves

Combine emulates AWS at the **edge of the VPC**: API calls from inside the VPC flow through Combine,
which rewrites identifiers, regions, endpoints, and ARNs between the emulated partition (what the
customer sees) and the host partition that actually backs it. This works because the traffic
*transits Combine*.

**EKS managed add-ons break that assumption.** When you install an add-on (CoreDNS, VPC CNI,
kube-proxy, EBS CSI, Pod Identity Agent, …), the EKS **managed control plane** reconciles the
add-on's workload and writes its container image references **directly into the cluster** — a path
that never passes through Combine. Those references point at the **commercial-partition** ECR
registry the control plane knows about, e.g.:

```
602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:v1.13.2-eksbuild.10
```

An isolated cluster **cannot use that reference**:

- **DNS** — the commercial host doesn't resolve inside the enclave.
- **Network** — even if it resolved, egress to commercial AWS is blocked (and in a true high-side
  region, simply doesn't exist).
- **TLS / identity** — the nodes trust Combine's CA and hold an emulated-partition identity; they
  can neither validate a real commercial ECR cert nor authenticate to it.

So the add-on's pods sit in `ImagePullBackOff`, and the add-on never becomes healthy. This is the
one place Combine's edge emulation can't reach, because the control plane writes *inside* the
cluster, behind Combine.

## What it does

This webhook is the missing interception point — **Combine's emulation, extended inside the
cluster**. On every Pod `CREATE` in the add-on namespace(s), it rewrites any commercial-partition
EKS add-on image to the **ISO-form** host that Combine already fronts:

```
602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:...     (control-plane injected)
        │  mutating webhook
        ▼
602401143452.dkr.ecr.us-iso-east-1.c2s.ic.gov/eks/coredns:...    (what the node pulls)
```

The account, repository, and tag/digest are preserved; only the **registry host** (region + DNS
suffix) changes. With an ISO-form reference, the pull rides **exactly the same path as any normal
in-cluster image pull**, which Combine already emulates end-to-end:

```
kubelet → ECR credential provider → ECR API (ISO host → Combine) → ISO auth token
        → registry pull (ISO host → Combine) → Combine proxies the layers from the real upstream
```

Nothing commercial-named ever has to reach Combine, and no new edge-side fronting is required — the
add-on simply becomes "a normal image pull," which already works.

Key design choices:

- **Mutates at the Pod level**, not the Deployment/DaemonSet template. The EKS add-on controller is
  free to keep reconciling the workload's image back to the commercial host; every pod it rolls is
  re-mutated on `CREATE`. The webhook and the control plane don't fight.
- **`failurePolicy: Ignore`.** If the webhook is unavailable, pods are admitted unmutated — i.e. the
  exact behavior you'd have without it. It can only *fix* pulls, never *break* them.
- **`hostNetwork: true`.** The webhook doesn't depend on the cluster CNI, so it can run on a node
  whose CNI add-on is itself broken (often the node you're trying to fix) — avoiding a cold-start
  deadlock.
- **Account allow list.** By default it only rewrites the well-known AWS-owned add-on registry
  accounts, so it never touches a customer's own images.

## How it fits with Combine

| Layer | Who emulates it |
| --- | --- |
| AWS API calls from the VPC (EC2, STS, ECR API, EKS, …) | Combine (edge / VPC boundary) |
| Normal in-cluster image pulls (ISO-form ECR) | Combine (edge) |
| **Add-on image refs injected by the control plane** | **This webhook (in-cluster)** |

It is a thin, optional in-cluster companion to Combine that covers the single path the edge can't
see. Think of it as Combine's rewriter, running where the control plane writes.

---

## Add-on support expectations

This webhook makes add-ons **installable and pullable** — it gets the control-plane-injected image
to pull. That is the whole of its job, and it's solved across the add-on class. Whether an add-on
then **functions** depends on what backend it talks to at runtime — which this webhook does not (and
cannot) address. Add-ons fall into three tiers:

| Tier | Add-ons | Webhook (image pull) | Runtime function |
| --- | --- | --- | --- |
| **Self-contained** | coredns, kube-proxy, vpc-cni, eks-pod-identity-agent, snapshot-controller, eks-node-monitoring-agent, aws-ec2-local-instance-store-csi-driver | ✅ | ✅ — only needs to run |
| **Needs IRSA + an emulated AWS service** | aws-ebs-csi-driver, aws-fsx-csi-driver, aws-mountpoint-s3-csi-driver | ✅ | ✅ if the role is wired and the backing service (EC2/FSx/S3) is emulated |
| **Needs a backend *data* endpoint** | aws-guardduty-agent, amazon-cloudwatch-observability | ✅ | ⛔ only works if that data endpoint is emulated + resolvable (see below) |

**Backend-data-endpoint add-ons.** Some agents call an AWS *data-plane* endpoint at runtime that is
distinct from the service's control API. Example: the GuardDuty agent pulls fine (this webhook
rewrites its image), starts, then crashes pinging `guardduty-data.<region>.amazonaws.com` — which
the enclave can't resolve. Combine emulating the GuardDuty *API* (`guardduty.<region>`) is not
enough; the *data* endpoint (`guardduty-data.<region>`) must also be emulated and routed to Combine
(DNS + firewall allow), the same way `ecr` / `sts` / `ec2` are. CloudWatch Observability is
analogous (its agents ship to CloudWatch Logs/Metrics data endpoints). These are per-service Combine
emulation tasks, **out of scope for this webhook** — it has already done its part (the image pulled).

So the honest summary: **the webhook delivers the image; a service-backed add-on additionally needs
its data endpoint emulated to be functional.**

---

## Layout

| File | Purpose |
| --- | --- |
| `main.go` | The webhook server (Go stdlib only — no Kubernetes client deps). |
| `main_test.go` | Unit tests for the rewrite logic. |
| `Dockerfile` | Multi-arch-safe build (cross-compiles natively, no qemu). |
| `deploy.yaml` | Namespace, Deployment, Service. |
| `webhook.yaml` | The `MutatingWebhookConfiguration` (separate, so re-applies don't wipe the caBundle). |
| `gen-certs.sh` | Self-signed serving cert + caBundle injection (dependency-free). |

## Configuration

Set on the Deployment container (`deploy.yaml`):

| Env var | Meaning | Example |
| --- | --- | --- |
| `COMBINE_ISO_REGION` | The emulated region Combine serves | `us-iso-east-1` (C2S), `us-isob-east-1` (SC2S) |
| `COMBINE_ISO_DNS_SUFFIX` | The emulated partition DNS suffix | `c2s.ic.gov` (C2S), `sc2s.sgov.gov` (SC2S) |
| `COMBINE_ADDON_ECR_ACCOUNTS` | Comma-separated allow list of AWS-owned add-on registry accounts for the host region(s) this partition maps onto. Empty ⇒ rewrite any commercial `dkr.ecr` host. | `602401143452,151742754352,013241004608` |

The per-region account numbers are published at
<https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html> (`602401143452` covers most
standard commercial regions; GovCloud and several opt-in regions have their own).

## Build & push

The image must live in your cluster's **ISO ECR** and be referenced ISO-form (so the webhook's own
image pulls through Combine like everything else). Build it where the Go/distroless base images are
reachable, push to your ISO ECR account, then set that reference in `deploy.yaml`.

```bash
IMG=<ISO_ECR_ACCOUNT>.dkr.ecr.us-iso-east-1.c2s.ic.gov/combine-eks-rewriter:0.1.0

# build for the NODES' architecture (amd64 unless you run Graviton/arm64 nodes)
docker build --platform linux/amd64 -t "$IMG" .
docker push "$IMG"     # push to whichever ECR endpoint your build host can reach; same repo
```

> The `Dockerfile` cross-compiles natively via `$BUILDPLATFORM`/`GOARCH`, so building amd64 on an
> arm64 machine (Apple Silicon) does **not** run the Go toolchain under qemu. Match `--platform` to
> your node architecture.

## Deploy

```bash
# 1. webhook config first (so its name exists for gen-certs to patch), then the workload
kubectl apply -f webhook.yaml
kubectl apply -f deploy.yaml

# 2. mint the serving cert + inject the caBundle (run this LAST)
./gen-certs.sh

# 3. confirm it's serving
kubectl -n combine-system get pods -l app=combine-eks-rewriter -o wide
kubectl -n combine-system get endpoints combine-eks-rewriter        # should list an IP
kubectl -n combine-system logs -l app=combine-eks-rewriter --tail=5 # "listening on :8443"
```

## Verify

Reinstall (or restart) an add-on and confirm its image is rewritten:

```bash
kubectl -n kube-system delete pod -l k8s-app=aws-node     # force a fresh create
kubectl -n kube-system get pod -l k8s-app=aws-node \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{": "}{.spec.initContainers[0].image}{"\n"}{end}'
# images should now read ...dkr.ecr.<ISO_REGION>.<ISO_DNS_SUFFIX>/...

kubectl -n combine-system logs -l app=combine-eks-rewriter | grep rewrite
# rewrite initContainers[0]: ...amazonaws.com... -> ...c2s.ic.gov...
```

Run the unit tests with `go test ./...`.

## Operational notes / gotchas

- **`caBundle` vs `kubectl apply`.** The caBundle is injected into the *live* `webhook.yaml` object
  by `gen-certs.sh`. Re-applying `webhook.yaml` resets it to empty — re-run `gen-certs.sh` after any
  such apply. (Re-applying `deploy.yaml` is always safe; that's why the two are separate files.)
- **Cert/caBundle must be from the same run.** `gen-certs.sh` deletes the pods so they remount the
  fresh secret immediately; otherwise a pod serving a stale cert against a new caBundle produces
  `tls: bad certificate`. For production, prefer **cert-manager** with a `cert-manager.io/inject-ca-from`
  annotation on the webhook config — it manages rotation and caBundle injection for you.
- **Bootstrap / `hostNetwork`.** Because the webhook runs on the host network it can come up even
  where the CNI is broken. Keep at least one replica on a healthy node; with `failurePolicy: Ignore`
  a momentary outage just means pods are admitted unmutated.
- **Node must still be able to pull from Combine.** This webhook fixes the image *reference*; the
  node still needs working ECR auth on the ISO path (the same one normal pulls use). A node that
  can't authenticate to Combine's ECR at all is a separate node/subnet problem.
- **Community add-ons** (metrics-server, cert-manager, external-dns, …) often pull from non-ECR
  registries (`registry.k8s.io`, `quay.io`). This webhook only rewrites `*.dkr.ecr.*.amazonaws.com`,
  so those are out of scope and need a separate mirror/egress strategy.
- **Scope.** `webhook.yaml` targets the `kube-system` namespace. Add other add-on namespaces (e.g.
  `amazon-cloudwatch`) to the `namespaceSelector` as you enable add-ons that deploy there.
