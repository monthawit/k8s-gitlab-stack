# Secrets

Nothing real lives in this directory in git — only `*.example` templates.
Before running `scripts/install.sh`:

```bash
cp rails.yaml.example rails.yaml
cp storage.config.example storage.config
```

Then fill in real values in both (Ceph RGW / S3 access key, secret key,
endpoint). `.gitignore` at the repo root already excludes the real files
from commits.

| File               | Becomes secret          | Used by                                             |
|---------------------|--------------------------|------------------------------------------------------|
| `rails.yaml`         | `gitlab-rails-storage`   | `global.appConfig.object_store` (artifacts/LFS/uploads/packages/registry/etc.) |
| `storage.config`     | `gitlab-backup-storage`  | `gitlab.toolbox.backups.objectStorage.config` (backup upload/download via s3cmd) |

Both files describe the **same** object storage endpoint but in two
different formats (fog-style vs s3cmd ini). Keep the scheme (http/https)
and addressing style (path-style vs virtual-hosted-style) consistent
between them — this project shipped with them disagreeing at one point,
which silently breaks whichever one is wrong.

Also create these two secrets manually (not templated here since their
values are generated, not user-authored config):

```bash
# Redis password -- must match auth.password in redis/redis-values.yaml
kubectl create secret generic gitlab-redis-password \
  -n gitlab \
  --from-literal=password='<same password as redis-values.yaml>'

# Postgres password -- mirror the CNPG-generated "gitlab" user password
PGPASS=$(kubectl get secret gitlab-postgresql-app -n gitlab -o jsonpath='{.data.password}' | base64 -d)
kubectl create secret generic gitlab-postgresql-password \
  -n gitlab \
  --from-literal=password="$PGPASS"
```

`scripts/install.sh` creates all four automatically.
