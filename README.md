# GitLab EE on Kubernetes

Self-managed GitLab EE (chart `gitlab-10.3.0`, app `v19.3.0`) deployed into
the `gitlab` namespace with external, in-cluster PostgreSQL (CloudNativePG),
Redis (Bitnami, standalone), and Ceph RGW (S3-compatible) object storage.

## Architecture

```
                         ┌─────────────────────┐
   Traefik (existing)    │   cert-manager       │  ClusterIssuer: certmanager01
   ingressClass: traefik │   (existing)          │  (pre-existing, not installed by this repo)
        │                └─────────────────────┘
        ▼
  Ingress: gitlab-webservice-default ──▶ gitlab-webservice-tls (cert-manager)
  Ingress: gitlab-kas                 ──▶ gitlab-wildcard-tls  (cert-manager)
        │
        ▼
  ┌─────────────────────────────────────────────────────────┐
  │  GitLab (Helm chart gitlab/gitlab)                        │
  │  webservice · sidekiq · gitaly · gitlab-shell · kas · toolbox │
  └─────────────────────────────────────────────────────────┘
        │                    │                     │
        ▼                    ▼                     ▼
 gitlab-postgresql-rw   gitlab-redis-master   Ceph RGW (rook-ceph)
 (CloudNativePG,        (Bitnami redis,       artifacts / LFS / uploads /
  Postgres 17,           standalone)          packages / registry / backups
  1 instance)                                 / ... (buckets pre-created)
```

Everything below `global.ingress` / the object storage buckets / cert-manager
is assumed to already exist in the cluster — this repo only installs
Postgres, Redis, and GitLab itself.

## Prerequisites

- A Kubernetes cluster with `kubectl`/`helm` access.
- Storage class `ceph-block` (or edit the storageClass fields below to match
  yours) — Postgres, Redis, and Gitaly's repo storage all use it.
- An `IngressClass` named `traefik` (or change `global.ingress.class` in
  `gitlab/gitlab-values.yaml`).
- A cert-manager `ClusterIssuer` named `certmanager01` (or change the
  `cert-manager.io/cluster-issuer` annotation in
  `gitlab/gitlab-values.yaml`), already `Ready`.
- An S3-compatible object store (Ceph RGW here) reachable from the cluster,
  with the buckets listed in `secrets/rails.yaml.example` already created.
- `helm` and `kubectl` pointed at the target cluster (`kubectl cluster-info`
  should succeed before running anything here).

## Layout

```
gitlab-stack/
├── postgresql/
│   └── postgres-cluster.yaml   # CloudNativePG Cluster manifest
├── redis/
│   └── redis-values.yaml       # Bitnami redis chart values
├── gitlab/
│   └── gitlab-values.yaml      # GitLab chart values (the real config)
├── secrets/
│   ├── *.example               # templates — copy, fill in, do not commit
│   └── README.md
└── scripts/
    ├── install.sh              # full install, idempotent
    └── verify.sh               # post-install health check
```

## Install

```bash
cd gitlab-stack/secrets
cp rails.yaml.example rails.yaml            # fill in real S3 credentials
cp storage.config.example storage.config    # fill in real S3 credentials
cd ..

# edit redis/redis-values.yaml: set auth.password to a real value
# (the CHANGE-ME-REDIS-PASSWORD placeholder must not be used as-is)

./scripts/install.sh
./scripts/verify.sh
```

`install.sh` runs, in order: CloudNativePG operator → Postgres cluster →
Redis → object storage secrets → GitLab. Each step is safe to re-run.

## Gotchas this config already works around

These were all hit and root-caused getting this stack running the first
time. The fixes are already baked into the YAML in this repo — documented
here so a future re-install or upgrade doesn't reintroduce them.

1. **`max_locks_per_transaction` (Postgres).** GitLab's `db:schema:load`
   loads the entire schema in a single transaction and needs far more locks
   than Postgres's default (64) allows — it fails with `out of shared
   memory / increase max_locks_per_transaction`. Fixed via
   `spec.postgresql.parameters.max_locks_per_transaction: "256"` in
   `postgresql/postgres-cluster.yaml`. This parameter requires a Postgres
   restart to take effect (CNPG does this automatically, in-place, on
   `kubectl apply`).

2. **`global.gatewayApi` must be nested under `global:`.** The chart
   defaults to installing an entire Envoy Gateway stack (GatewayClass /
   Gateway / HTTPRoute, plus cluster-wide `MutatingWebhookConfiguration`
   and `ValidatingAdmissionPolicy` resources) even when you only want
   classic Ingress. A **top-level** `gatewayApi:` key in values is silently
   ignored — it must be `global.gatewayApi.enabled: false`. Also note
   `global.gatewayApi.configureCertmanager` defaults to `true`
   *independently* of `enabled`, and if left on it spins up a broken
   `certmanager-issuer` job trying to attach an ACME solver to a Gateway
   that doesn't exist. Both are disabled in `gitlab/gitlab-values.yaml`.

3. **A failed one-shot migrations `Job` blocks all future upgrades.**
   Kubernetes `Job` pod templates are immutable, so if the migrations Job
   ever fails permanently (e.g. hits `activeDeadlineSeconds`), a later
   `helm upgrade` cannot patch it and the upgrade fails with
   `context canceled` or similar. Fix: `kubectl delete job <name> -n
   gitlab` before re-running the upgrade — Helm recreates it cleanly.

4. **Shared TLS secret across ingresses drops hostnames.** If two
   Ingress objects point `tls[].secretName` at the *same* secret,
   cert-manager's ingress-shim does not reliably merge both hostnames
   into one `Certificate` — in practice it kept only one hostname's SAN,
   leaving the other served over a certificate that didn't cover it (a
   real, silent TLS mismatch — `curl -k` won't show it, only real
   hostname validation will). Fixed by giving the webservice ingress its
   own dedicated secret: `gitlab.webservice.ingress.tls.secretName:
   gitlab-webservice-tls`, separate from the kas ingress's
   `gitlab-wildcard-tls`.

5. **CNPG's own basic-auth secret isn't what the GitLab chart wants.**
   CloudNativePG auto-generates `gitlab-postgresql-app`
   (`kubernetes.io/basic-auth`, includes `username`/`password`/etc). The
   GitLab chart wants a plain `Opaque` secret with just a `password` key
   (`global.psql.password.secret`/`key`). `install.sh` mirrors the value
   across once; if the CNPG cluster is ever recreated, re-run that step
   (or `install.sh` again) to resync.

## Verify

```bash
./scripts/verify.sh
```

Checks: all pods Running/Ready, Helm release `deployed`, Postgres cluster
healthy, migrations `Job` `Complete`, both `Certificate`s `READY=True`, and
an end-to-end HTTP check against the webservice.

## Notes

- `edition: ee` — this deploys GitLab Enterprise Edition. Without a
  license applied it runs in the free-tier feature set.
- `gitlab.gitaly.replicas`/registry/runner/Prometheus are intentionally
  minimal/disabled here (`registry.enabled: false`,
  `gitlab-runner.install: false`, `prometheus.install: false`) — this
  cluster uses its own existing monitoring stack and hasn't turned on the
  container registry yet. Flip these on in `gitlab/gitlab-values.yaml`
  when needed (the registry object storage secret name is already wired
  up: `gitlab-registry-storage`, not yet created).
- Single-instance Postgres and Redis (no HA) — fine for the current
  scale, but a real single point of failure. Bump
  `postgresql/postgres-cluster.yaml`'s `spec.instances` and
  `redis/redis-values.yaml`'s `architecture` if that changes.
