# Cluster-wide OpenBao secret store (Kubernetes auth)

This directory is synced by the `external-secrets` Argo application
(`infra-apps/templates/external-secrets.yaml`) and provides a single
`ClusterSecretStore` named `openbao-backend` that authenticates to OpenBao with
the **Kubernetes auth method** instead of a static token.

## Why

The per-namespace pattern (`manifests/<app>/secretstore.yaml`) requires, for
every new namespace:

1. Create an OpenBao token by hand.
2. `kubectl create secret generic openbao-credentials --from-literal=OPENBAO_TOKEN=...`
   in the new namespace.
3. Commit a `SecretStore` that points at that secret.

That is three manual steps per app, and the tokens never rotate.

With this `ClusterSecretStore`, adding a new app is **one file** - the
`ExternalSecret` itself. No token, no namespace secret, no `SecretStore`.
ESO mints a short-lived ServiceAccount token via the TokenRequest API, OpenBao
validates it with a `TokenReview`, and hands back a lease-bound token that
expires on its own.

## One-time setup

`server.authDelegator.enabled` is already `true` in `values/openbao-values.yaml`,
so OpenBao's ServiceAccount can perform `TokenReview`. The remaining OpenBao-side
configuration is not managed by Argo (it lives inside OpenBao's own state), so
run it once against an unsealed OpenBao:

```sh
BAO_TOKEN=<root-or-admin-token> ./scripts/openbao-k8s-auth-setup.sh
```

That script enables `auth/kubernetes`, points it at the in-cluster API server,
writes an `external-secrets-read` policy scoped to `kv/data/*` + `kv/metadata/*`,
and creates the role `external-secrets` bound to the `openbao-auth`
ServiceAccount in the `external-secrets` namespace.

## Using it

In any namespace, reference the store by kind `ClusterSecretStore`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-app-secrets
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-backend
    kind: ClusterSecretStore   # <- the only change from the old pattern
  target:
    name: my-app-secrets
    creationPolicy: Owner
  data:
    - secretKey: API_TOKEN
      remoteRef:
        key: my-app/api
        property: token
```

## Migrating an existing app

The existing per-namespace `SecretStore`s still work and are untouched. To move
an app over:

1. Change `kind: SecretStore` to `kind: ClusterSecretStore` in the app's
   `ExternalSecret` (the name `openbao-backend` stays the same).
2. Confirm the secret still materialises:
   `kubectl get externalsecret -n <ns>` should report `SecretSynced`.
3. Delete the app's `manifests/<app>/*secretstore.yaml` and the manual
   `openbao-credentials` secret in that namespace.

## Scoping

`ClusterSecretStore` is cluster-wide: with the policy above, any namespace that
can create an `ExternalSecret` can read any path under `kv/`. To restrict which
namespaces may use the store, add `spec.conditions` to
`openbao-clustersecretstore.yaml`:

```yaml
spec:
  conditions:
    - namespaceSelector:
        matchLabels:
          openbao-access: "true"
```

If an app needs a genuinely narrower OpenBao policy, keep a namespaced
`SecretStore` for it - but still use `auth.kubernetes` with its own role rather
than a static token, e.g.:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: openbao-backend
  namespace: my-app
spec:
  provider:
    vault:
      server: http://openbao.openbao.svc.cluster.local:8200
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: my-app          # bao write auth/kubernetes/role/my-app ...
          serviceAccountRef:
            name: default       # any SA in this namespace
```

Namespaced stores mint the token in their own namespace, so no
`serviceAccountRef.namespace` is set and no extra RBAC is needed.
