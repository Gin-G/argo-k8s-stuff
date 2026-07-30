#!/usr/bin/env bash
#
# One-time bootstrap of the Kubernetes auth method in OpenBao so that External
# Secrets can log in without a manually created token.
#
# Run once against an unsealed OpenBao. Re-running is safe - every step is
# idempotent.
#
# Requires: kubectl, and a BAO_TOKEN with permission to write auth/ and sys/policy.
#
#   BAO_TOKEN=<root-or-admin-token> ./scripts/openbao-k8s-auth-setup.sh
#
# Optional overrides:
#   BAO_NAMESPACE   namespace OpenBao runs in            (default: openbao)
#   BAO_POD         pod to exec into                     (default: openbao-0)
#   KV_MOUNT        kv-v2 mount to grant read access to  (default: kv)
#   POLICY_NAME     policy created for ESO               (default: external-secrets-read)
#   ROLE_NAME       kubernetes auth role for ESO         (default: external-secrets)
#   ESO_NAMESPACE   namespace ESO runs in                (default: external-secrets)
#   ESO_SA          service account ESO authenticates as (default: openbao-auth)
#   TOKEN_TTL       ttl of tokens issued to ESO          (default: 1h)

set -euo pipefail

BAO_NAMESPACE="${BAO_NAMESPACE:-openbao}"
BAO_POD="${BAO_POD:-openbao-0}"
KV_MOUNT="${KV_MOUNT:-kv}"
POLICY_NAME="${POLICY_NAME:-external-secrets-read}"
ROLE_NAME="${ROLE_NAME:-external-secrets}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
ESO_SA="${ESO_SA:-openbao-auth}"
TOKEN_TTL="${TOKEN_TTL:-1h}"

if [[ -z "${BAO_TOKEN:-}" ]]; then
  echo "BAO_TOKEN must be set to a token that can write auth/ and sys/policy." >&2
  exit 1
fi

bao() {
  kubectl exec -i -n "${BAO_NAMESPACE}" "${BAO_POD}" -- \
    env BAO_TOKEN="${BAO_TOKEN}" BAO_ADDR="http://127.0.0.1:8200" bao "$@"
}

echo "==> Enabling the kubernetes auth method (if not already enabled)"
if bao auth list -format=json | grep -q '"kubernetes/"'; then
  echo "    already enabled, skipping"
else
  bao auth enable kubernetes
fi

echo "==> Configuring auth/kubernetes"
# The agent injector points at this same mount (server.injector.authPath), so an
# existing config may already be in use. Overwriting it could break agent-based
# logins, so leave it alone unless FORCE_CONFIG=true.
#
# OpenBao runs in-cluster with authDelegator enabled, so it reviews tokens using
# its own service account token and the in-cluster CA. Leaving kubernetes_ca_cert
# and token_reviewer_jwt unset makes it read both from /var/run/secrets at
# request time, which survives token and CA rotation.
if bao read auth/kubernetes/config >/dev/null 2>&1 && [[ "${FORCE_CONFIG:-false}" != "true" ]]; then
  echo "    already configured, leaving as-is (FORCE_CONFIG=true to overwrite):"
  bao read auth/kubernetes/config
else
  bao write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc.cluster.local:443"
fi

echo "==> Writing policy ${POLICY_NAME}"
bao policy write "${POLICY_NAME}" - <<EOF
path "${KV_MOUNT}/data/*" {
  capabilities = ["read"]
}

path "${KV_MOUNT}/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

echo "==> Writing role auth/kubernetes/role/${ROLE_NAME}"
bao write "auth/kubernetes/role/${ROLE_NAME}" \
  bound_service_account_names="${ESO_SA}" \
  bound_service_account_namespaces="${ESO_NAMESPACE}" \
  token_policies="${POLICY_NAME}" \
  token_ttl="${TOKEN_TTL}"

echo "==> Verifying role auth/kubernetes/role/${ROLE_NAME}"
bao read "auth/kubernetes/role/${ROLE_NAME}"

echo
echo "Done. The ClusterSecretStore 'openbao-k8s-backend' can now authenticate."
echo "Verify with:"
echo "  kubectl get clustersecretstore openbao-k8s-backend"
