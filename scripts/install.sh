#!/usr/bin/env bash
#
# Installs GitLab EE on Kubernetes into the "gitlab" namespace:
#   CloudNativePG (Postgres 17) -> Redis (Bitnami, standalone) -> object
#   storage secrets -> GitLab Helm chart.
#
# This mirrors the exact steps and config that were verified working in
# this repo. Read README.md first — several of the settings baked into
# the YAML files here exist specifically to avoid failures this project
# hit during setup (see "Gotchas" in the README). Re-running this script
# is safe: every step is idempotent (kubectl apply / create --dry-run
# check / helm upgrade --install).
#
# Requires: kubectl and helm already configured against the target
# cluster, and secrets/rails.yaml + secrets/storage.config already
# created from their .example templates (see secrets/README.md).

set -euo pipefail

NAMESPACE="gitlab"
CHART_VERSION="10.3.0"
POSTGRES_PASSWORD_SECRET="gitlab-postgresql-password"
REDIS_PASSWORD_SECRET="gitlab-redis-password"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { printf '\n==> %s\n' "$1"; }

log "Checking cluster access"
kubectl cluster-info >/dev/null

log "Creating namespace '$NAMESPACE' (if missing)"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

# ---------------------------------------------------------------------------
# 1. PostgreSQL (CloudNativePG)
# ---------------------------------------------------------------------------
log "Installing/upgrading the CloudNativePG operator"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
helm repo update cnpg >/dev/null
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace

log "Applying the GitLab PostgreSQL cluster"
kubectl apply -f "$ROOT_DIR/postgresql/postgres-cluster.yaml"

log "Waiting for the PostgreSQL cluster to become healthy (this can take a few minutes)"
kubectl wait --for=jsonpath='{.status.phase}'="Cluster in healthy state" \
  cluster/gitlab-postgresql -n "$NAMESPACE" --timeout=10m

if ! kubectl get secret "$POSTGRES_PASSWORD_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  log "Mirroring the CNPG-generated app password into $POSTGRES_PASSWORD_SECRET"
  # CNPG auto-creates gitlab-postgresql-app (kubernetes.io/basic-auth) with the
  # real "gitlab" user password. The GitLab chart wants a plain secret with
  # just a "password" key, pointed at by global.psql.password in
  # gitlab/gitlab-values.yaml -- so mirror it once here.
  PGPASS=$(kubectl get secret gitlab-postgresql-app -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
  kubectl create secret generic "$POSTGRES_PASSWORD_SECRET" \
    -n "$NAMESPACE" \
    --from-literal=password="$PGPASS"
else
  echo "  $POSTGRES_PASSWORD_SECRET already exists, leaving it as-is"
fi

# ---------------------------------------------------------------------------
# 2. Redis
# ---------------------------------------------------------------------------
log "Installing/upgrading Redis"
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
helm repo update bitnami >/dev/null
helm upgrade --install gitlab-redis bitnami/redis \
  -n "$NAMESPACE" \
  -f "$ROOT_DIR/redis/redis-values.yaml"

if ! kubectl get secret "$REDIS_PASSWORD_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  log "Creating $REDIS_PASSWORD_SECRET"
  echo "  NOTE: this must match auth.password in redis/redis-values.yaml."
  echo "  Edit that file to a real password before running this in a real environment --"
  echo "  the CHANGE-ME-REDIS-PASSWORD placeholder is not safe to use as-is."
  REDIS_PASSWORD=$(grep -E '^\s*password:' "$ROOT_DIR/redis/redis-values.yaml" | head -1 | awk '{print $2}')
  kubectl create secret generic "$REDIS_PASSWORD_SECRET" \
    -n "$NAMESPACE" \
    --from-literal=password="$REDIS_PASSWORD"
else
  echo "  $REDIS_PASSWORD_SECRET already exists, leaving it as-is"
fi

# ---------------------------------------------------------------------------
# 3. Object storage secrets
# ---------------------------------------------------------------------------
log "Creating object storage secrets"
if [ ! -f "$ROOT_DIR/secrets/rails.yaml" ]; then
  echo "  ERROR: $ROOT_DIR/secrets/rails.yaml not found." >&2
  echo "  Copy secrets/rails.yaml.example to secrets/rails.yaml and fill in real credentials." >&2
  exit 1
fi
if [ ! -f "$ROOT_DIR/secrets/storage.config" ]; then
  echo "  ERROR: $ROOT_DIR/secrets/storage.config not found." >&2
  echo "  Copy secrets/storage.config.example to secrets/storage.config and fill in real credentials." >&2
  exit 1
fi

kubectl get secret gitlab-rails-storage -n "$NAMESPACE" >/dev/null 2>&1 || \
  kubectl create secret generic gitlab-rails-storage \
    -n "$NAMESPACE" \
    --from-file=connection="$ROOT_DIR/secrets/rails.yaml"

kubectl get secret gitlab-backup-storage -n "$NAMESPACE" >/dev/null 2>&1 || \
  kubectl create secret generic gitlab-backup-storage \
    -n "$NAMESPACE" \
    --from-file=config="$ROOT_DIR/secrets/storage.config"

# ---------------------------------------------------------------------------
# 4. GitLab
# ---------------------------------------------------------------------------
log "Installing/upgrading GitLab (chart version $CHART_VERSION)"
helm repo add gitlab https://charts.gitlab.io >/dev/null
helm repo update gitlab >/dev/null
helm upgrade --install gitlab gitlab/gitlab \
  -n "$NAMESPACE" \
  -f "$ROOT_DIR/gitlab/gitlab-values.yaml" \
  --version "$CHART_VERSION" \
  --wait \
  --timeout 15m

log "Done. Run scripts/verify.sh to check pod/cert health."
