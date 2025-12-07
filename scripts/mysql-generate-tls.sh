#!/usr/bin/env bash
set -euo pipefail

# Generate MySQL TLS certificates and store them in a Kubernetes secret
# This script can be run manually if the in-cluster Job fails or for local testing
#
# Usage: ./mysql-generate-tls.sh [namespace]
#
# Prerequisites: openssl, kubectl with cluster access

NAMESPACE="${1:-mysql-system}"
SECRET_NAME="mysql-tls-certs"
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

echo "📜 Generating MySQL TLS certificates..."
cd "$WORKDIR"

# Check if secret already exists
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" 2>/dev/null; then
  echo "⚠️  Secret '$SECRET_NAME' already exists in namespace '$NAMESPACE'"
  read -p "Do you want to regenerate? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborting."
    exit 0
  fi
  kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE"
fi

echo "🔐 Generating CA..."
openssl genrsa 2048 > ca-key.pem
openssl req -new -x509 -nodes -days 3650 -key ca-key.pem -out ca.pem \
  -subj "/CN=MySQL-CA/O=WordPress-SaaS"

echo "🔐 Generating server certificate..."
openssl req -newkey rsa:2048 -nodes -keyout server-key.pem -out server-req.pem \
  -subj "/CN=mysql.${NAMESPACE}.svc.cluster.local/O=WordPress-SaaS"

# Add SAN for multiple DNS names
cat > server-ext.cnf << EOF
subjectAltName = DNS:mysql.${NAMESPACE}.svc.cluster.local,DNS:mysql.${NAMESPACE}.svc,DNS:mysql,DNS:localhost
EOF

openssl x509 -req -in server-req.pem -days 3650 -CA ca.pem -CAkey ca-key.pem \
  -set_serial 01 -out server-cert.pem -extfile server-ext.cnf

echo "🔐 Generating client certificate..."
openssl req -newkey rsa:2048 -nodes -keyout client-key.pem -out client-req.pem \
  -subj "/CN=MySQL-Client/O=WordPress-SaaS"
openssl x509 -req -in client-req.pem -days 3650 -CA ca.pem -CAkey ca-key.pem \
  -set_serial 02 -out client-cert.pem

echo "📦 Creating Kubernetes secret..."
kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-file=ca.pem \
  --from-file=server-cert.pem \
  --from-file=server-key.pem \
  --from-file=client-cert.pem \
  --from-file=client-key.pem

echo ""
echo "✅ TLS certificates generated and stored in secret '$SECRET_NAME'"
echo ""
echo "📋 To verify:"
echo "   kubectl get secret $SECRET_NAME -n $NAMESPACE"
echo ""
echo "📋 To restart MySQL to pick up new certs:"
echo "   kubectl rollout restart statefulset/mysql -n $NAMESPACE"
