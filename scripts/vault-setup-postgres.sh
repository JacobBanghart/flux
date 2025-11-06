#!/usr/bin/env bash
set -euo pipefail
# Bootstrap Vault database secrets engine roles for multiple apps against Bitnami Postgres
# Requirements: postgres deployed, Vault unsealed & logged in with root token exported as VAULT_TOKEN
# Usage: VAULT_TOKEN=... ./scripts/vault-setup-postgres.sh

VAULT_NAMESPACE="vault"   # k8s namespace of vault
PG_HOST="postgres.data.svc.cluster.local"
PG_PORT=5432
PG_ADMIN_SECRET_NS="data"
PG_ADMIN_SECRET_NAME="postgres-admin"

# Get postgres superuser password from K8s secret
PG_SUPER_PASS=$(kubectl get secret -n "$PG_ADMIN_SECRET_NS" "$PG_ADMIN_SECRET_NAME" -o jsonpath='{.data.postgres-password}' | base64 -d)

export VAULT_ADDR="http://vault.vault.svc.cluster.local:8200"
if ! kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status >/dev/null 2>&1; then
  echo "[ERR] Vault not reachable" >&2; exit 1; fi

# Enable db engine if not present
if ! kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault secrets list -format=json | grep -q '"database/"'; then
  kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault secrets enable database
fi

# Configure connection (idempotent)
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles="immich,openedx" \
  connection_url="postgresql://{{username}}:{{password}}@${PG_HOST}:${PG_PORT}/postgres?sslmode=disable" \
  username="postgres" \
  password="${PG_SUPER_PASS}"

# Create databases if they don't exist
for DB in immich openedx; do
  kubectl exec -n data deploy/postgres-postgresql -- bash -c "psql -U postgres -tc 'SELECT 1 FROM pg_database WHERE datname=\'${DB}\'' | grep -q 1 || createdb -U postgres ${DB}" || true
done

# Write roles
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault write database/roles/immich \
  db_name=postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' INHERIT; GRANT ALL PRIVILEGES ON DATABASE immich TO \"{{name}}\";" \
  default_ttl=1h \
  max_ttl=24h

kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault write database/roles/openedx \
  db_name=postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' INHERIT; GRANT ALL PRIVILEGES ON DATABASE openedx TO \"{{name}}\";" \
  default_ttl=1h \
  max_ttl=24h

# Example: generate creds
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault read database/creds/immich
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault read database/creds/openedx

echo "[INFO] Done. Use 'vault read database/creds/<role>' for dynamic creds." 
