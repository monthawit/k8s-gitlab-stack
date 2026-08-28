#!/usr/bin/env bash
#
#  Post-install health check for the GitLab stack. Safe to re-run any time.

set -uo pipefail

NAMESPACE="gitlab"

section() { printf '\n=== %s ===\n' "$1"; }

section "Pods"
kubectl get pods -n "$NAMESPACE"

section "Helm release status"
helm status gitlab -n "$NAMESPACE" 2>&1 | head -5

section "PostgreSQL cluster"
kubectl get cluster gitlab-postgresql -n "$NAMESPACE"

section "Jobs (migrations should be Complete)"
kubectl get jobs -n "$NAMESPACE"

section "Certificates (both should be READY=True)"
kubectl get certificate -n "$NAMESPACE"

section "Ingresses"
kubectl get ingress -n "$NAMESPACE"

section "gitlab.apps.<domain> TLS check (through the webservice ingress)"
GITLAB_HOST=$(kubectl get ingress gitlab-webservice-default -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
if [ -n "${GITLAB_HOST:-}" ]; then
  echo "Host: $GITLAB_HOST"
  kubectl run verify-curl --rm -i --restart=Never --image=curlimages/curl -n "$NAMESPACE" -- \
    curl -s -o /dev/null -w "HTTP %{http_code}\n" \
    "http://gitlab-webservice-default.$NAMESPACE.svc.cluster.local:8181/users/sign_in"
else
  echo "Could not read ingress host"
fi

section "Sidekiq recent errors (should be empty)"
kubectl logs -n "$NAMESPACE" -l app=sidekiq -c sidekiq --tail=200 2>/dev/null \
  | grep -i "error\|fatal\|exception" | grep -v "0 errors\|error_count" | tail -20
echo "(no output above = no errors found)"
