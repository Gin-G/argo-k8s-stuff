# OpenBao Kubernetes auth bootstrap (GitOps)

Configures the Kubernetes auth method inside OpenBao without needing `kubectl`
or CLI access to the cluster. Enabling the auth method, writing the policy and
writing the role all live in OpenBao's own state rather than in Kubernetes, so
they can't be expressed as manifests - but they *can* be driven by a Job that
Argo runs for you.

This is the remote-friendly equivalent of `scripts/openbao-k8s-auth-setup.sh`.
Use whichever is convenient; both are idempotent and produce identical state.

## Prerequisite: where the admin token lives

The Job authenticates to OpenBao with an existing token, read from a secret in
its own namespace:

| | |
|---|---|
| Secret name | `openbao-credentials` |
| Key | `OPENBAO_TOKEN` |
| Namespace | whatever `openbao-bootstrap.namespace` is set to in `infra-apps/values.yaml` |

That is the same name and key already used by the per-namespace SecretStores, so
**point `namespace` at a namespace that already holds one**. It is currently set
to `nickknows`, whose token has the write access described below. Nothing needs
to be created by hand.

The catch: that token must be allowed to write `sys/policy/*` and `auth/*`. The
tokens handed to the SecretStores may be read-only. If the Job fails with a
403, the token is too narrow - either widen it or run the script from a machine
with cluster access instead.

## Running it

1. In `infra-apps/values.yaml`, set the namespace and enable the app:

   ```yaml
   "openbao-bootstrap":
     enable: true
     namespace: nickknows   # or any namespace holding openbao-credentials
   ```

2. Commit and push. Argo creates the `openbao-bootstrap` Application, which runs
   the Job as a sync hook.

3. Check the result in the Argo UI, or:

   ```sh
   kubectl logs -n <namespace> job/openbao-k8s-auth-bootstrap
   ```

4. Confirm the store came up:

   ```sh
   kubectl get clustersecretstore openbao-k8s-backend
   ```

5. Set `enable: false` again and push. The Application is removed and the Job
   with it. Leaving it enabled is harmless - the script is idempotent and the
   Job re-runs only on sync - but there's no reason to keep it around.

## Why a separate Application

The Job is not attached to the `openbao` Application on purpose. A failed sync
hook marks its Application degraded, and degrading the OpenBao app itself over a
bootstrap step would be a bad trade. Isolated in its own Application, a failure
is visible and contained.

## Not clobbering the injector

`server.injector.authPath` in `values/openbao-values.yaml` is `auth/kubernetes` -
the same mount this configures. If `auth/kubernetes/config` already exists, the
script prints it and leaves it alone rather than overwriting settings the agent
injector may depend on. Set `FORCE_CONFIG=true` on the Job to overwrite
deliberately.

The policy and role are always written; they are additive and specific to
External Secrets.

## What it configures

- Auth method `kubernetes` at `auth/kubernetes`, pointed at
  `https://kubernetes.default.svc.cluster.local:443`.
- Policy `external-secrets-read`: read on `kv/data/*`, read+list on
  `kv/metadata/*`.
- Role `external-secrets`, bound to the `openbao-auth` ServiceAccount in the
  `external-secrets` namespace, issuing 1h tokens with that policy.

These values are set as env vars on the Job in `job.yaml` and must stay in sync
with `manifests/external-secrets/openbao-clustersecretstore.yaml`.
