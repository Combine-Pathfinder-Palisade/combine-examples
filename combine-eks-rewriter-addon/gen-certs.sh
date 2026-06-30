#!/usr/bin/env bash
# Generate a self-signed CA + serving cert for the webhook, store the cert as a TLS secret, and
# inject the CA into the MutatingWebhookConfiguration's caBundle.
#
# Run AFTER `kubectl apply -f deploy.yaml -f webhook.yaml`. This is dependency-free; for a managed
# alternative, use cert-manager + a ca-injector annotation instead (see README).
#
# IMPORTANT: the serving cert (secret) and the caBundle (webhook config) must come from the SAME
# run. This script force-deletes the pods (rather than `rollout restart`) so they immediately
# remount the freshly-generated secret with no surge/host-port conflict and no stale-cert window.
set -euo pipefail

NS=combine-system
SVC=combine-eks-rewriter
CN="$SVC.$NS.svc"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# CA
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/ca.key" -out "$WORK/ca.crt" -subj "/CN=combine-eks-rewriter-ca"

# Serving cert (SANs must match the in-cluster Service DNS names)
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/tls.key" -out "$WORK/tls.csr" -subj "/CN=$CN"
cat > "$WORK/ext.cnf" <<EOF
subjectAltName=DNS:$CN,DNS:$SVC.$NS.svc.cluster.local
EOF
openssl x509 -req -in "$WORK/tls.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
  -CAcreateserial -days 3650 -extfile "$WORK/ext.cnf" -out "$WORK/tls.crt"

# Store the serving cert as the secret the Deployment mounts at /tls
kubectl -n "$NS" create secret tls "$SVC-tls" \
  --cert="$WORK/tls.crt" --key="$WORK/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

# Inject the CA so the API server trusts the webhook's serving cert
CABUNDLE=$(base64 < "$WORK/ca.crt" | tr -d '\n')
kubectl patch mutatingwebhookconfiguration "$SVC" --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"$CABUNDLE\"}]"

# Force pods to remount the fresh secret (delete, not rollout restart — clean with hostNetwork)
kubectl -n "$NS" delete pod -l app="$SVC" --ignore-not-found

echo "done: TLS secret created, caBundle injected, pods recreated."
echo "the cert and caBundle are now from the same run; the webhook should serve without 'bad certificate'."
