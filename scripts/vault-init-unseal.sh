#!/usr/bin/env bash
set -euo pipefail

# Simple helper to initialize (once) and unseal a single Vault raft cluster pod.
# It will:
#  1. Check if Vault is already initialized.
#  2. If not, run vault operator init capturing unseal keys & root token to a secure file with 600 perms.
#  3. Unseal the target pod using the first <THRESHOLD> keys.
#  4. Optionally (if replicas >1 later) can unseal additional pods with --pods "vault-0 vault-1 ...".
#
# WARNING: The output file contains sensitive data. Move it to a password manager and then securely delete.
#
# Usage examples:
#   ./vault-init-unseal.sh                # operates on vault-0 in namespace vault
#   ./vault-init-unseal.sh -n vault -p vault-0
#   ./vault-init-unseal.sh --pods "vault-0 vault-1 vault-2"   # after scaling the StatefulSet
#
# Flags:
#   -n|--namespace   Kubernetes namespace (default: vault)
#   -p|--pod         Primary pod to init/unseal (default: vault-0)
#   --pods           Space-separated list of pods to unseal (default: primary pod only)
#   -f|--file        Output file for init keys (default: vault-init.txt)
#   -s|--shares      Key shares (default: 5)
#   -t|--threshold   Key threshold (default: 3)
#   --force-retry    Proceed even if previous partial init file exists (will not re-init an initialized Vault)
#
# Idempotent behavior:
#   - If already initialized, it skips init and reads keys from the file if present; otherwise prompts.
#
# Dependencies: kubectl, awk, grep, sed.

NS="vault"
PRIMARY_POD="vault-0"
OUTPUT_FILE="vault-init.txt"
SHARES=5
THRESHOLD=3
PODS=""
FORCE_RETRY=false
PRINT_KEYS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NS="$2"; shift 2;;
    -p|--pod) PRIMARY_POD="$2"; shift 2;;
    --pods) PODS="$2"; shift 2;;
    -f|--file) OUTPUT_FILE="$2"; shift 2;;
    -s|--shares) SHARES="$2"; shift 2;;
    -t|--threshold) THRESHOLD="$2"; shift 2;;
    --force-retry) FORCE_RETRY=true; shift 1;;
  --print-keys) PRINT_KEYS=true; shift 1;;
    -h|--help)
      sed -n '1,/^$/{/#!\/usr/d;p}' "$0"
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ -z "$PODS" ]]; then
  PODS="$PRIMARY_POD"
fi

if ! kubectl get pod -n "$NS" "$PRIMARY_POD" >/dev/null 2>&1; then
  echo "[ERROR] Pod $PRIMARY_POD not found in namespace $NS" >&2
  exit 1
fi

# Wait for the main container to be in Running state (even if not Ready yet) so 'vault status' can execute.
echo "[INFO] Waiting for $PRIMARY_POD container to start..."
ATTEMPTS=0
MAX_ATTEMPTS=30
while true; do
  PHASE=$(kubectl get pod -n "$NS" "$PRIMARY_POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$PHASE" == "Running" ]]; then
    # Double-check container state
    READY_CONTAINERS=$(kubectl get pod -n "$NS" "$PRIMARY_POD" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || true)
    # We only need it started, not necessarily Ready (will be Unready while sealed)
    break
  fi
  if (( ATTEMPTS >= MAX_ATTEMPTS )); then
    echo "[ERROR] Pod $PRIMARY_POD not in Running state after $MAX_ATTEMPTS checks (phase=$PHASE)." >&2
    kubectl -n "$NS" describe pod "$PRIMARY_POD" | sed 's/^/[DESCRIBE] /'
    exit 1
  fi
  ((ATTEMPTS++))
  sleep 2
done

echo "[INFO] Pod phase Running (attempts=$ATTEMPTS). Checking Vault initialization status..."
if kubectl exec -n "$NS" "$PRIMARY_POD" -- sh -c 'command -v vault' >/dev/null 2>&1; then
  # Vault status returns exit code 0 (active), 2 (sealed/uninitialized). Treat 0 or 2 as acceptable.
  set +e
  STATUS_JSON_RAW=$(kubectl exec -n "$NS" "$PRIMARY_POD" -- sh -c 'vault status -format=json' 2>/dev/null)
  STATUS_RC=$?
  set -e
  if [[ $STATUS_RC -ne 0 && $STATUS_RC -ne 2 ]]; then
    echo "[ERROR] 'vault status' unexpected exit code $STATUS_RC inside $PRIMARY_POD. Logs follow:" >&2
    kubectl -n "$NS" logs "$PRIMARY_POD" | tail -n 50 | sed 's/^/[LOG] /'
    exit 1
  fi
  STATUS_JSON="$STATUS_JSON_RAW"
else
  echo "[ERROR] Vault binary not found in $PRIMARY_POD PATH" >&2
  kubectl -n "$NS" logs "$PRIMARY_POD" | tail -n 30 | sed 's/^/[LOG] /'
  exit 1
fi

INITIALIZED=$(echo "$STATUS_JSON" | grep '"initialized"' | awk -F': ' '{print $2}' | tr -d ' ,')
SEALED=$(echo "$STATUS_JSON" | grep '"sealed"' | awk -F': ' '{print $2}' | tr -d ' ,')

if [[ "$INITIALIZED" == "true" ]]; then
  echo "[INFO] Vault already initialized. Skipping init."
else
  echo "[INFO] Vault not initialized. Initializing..."
  if [[ -f "$OUTPUT_FILE" && $FORCE_RETRY == false ]]; then
    echo "[ERROR] $OUTPUT_FILE already exists. Use --force-retry to reuse/overwrite or move the file." >&2
    exit 1
  fi
  kubectl exec -n "$NS" "$PRIMARY_POD" -- \
    vault operator init -key-shares=$SHARES -key-threshold=$THRESHOLD > "$OUTPUT_FILE"
  chmod 600 "$OUTPUT_FILE"
  echo "[INFO] Init output written to $OUTPUT_FILE (protect this file!)."
fi

if [[ ! -f "$OUTPUT_FILE" ]]; then
  echo "[ERROR] Missing $OUTPUT_FILE containing unseal keys. Provide it with -f or run without skipping init." >&2
  exit 1
fi

# Extract keys and root token
UNSEAL_KEYS=($(grep -E '^Unseal Key ' "$OUTPUT_FILE" | awk -F': ' '{print $2}'))
ROOT_TOKEN=$(grep '^Initial Root Token:' "$OUTPUT_FILE" | awk -F': ' '{print $2}')

if [[ ${#UNSEAL_KEYS[@]} -lt $THRESHOLD ]]; then
  echo "[ERROR] Found only ${#UNSEAL_KEYS[@]} unseal keys, need at least threshold $THRESHOLD" >&2
  exit 1
fi

echo "[INFO] Unsealing pods: $PODS (threshold $THRESHOLD)"
for POD in $PODS; do
  if ! kubectl get pod -n "$NS" "$POD" >/dev/null 2>&1; then
    echo "[WARN] Pod $POD not found yet, skipping"
    continue
  fi
  # Refresh status each pod
  POD_STATUS=$(kubectl exec -n "$NS" "$POD" -- sh -c 'vault status -format=json' 2>/dev/null || true)
  POD_INITIALIZED=$(echo "$POD_STATUS" | grep '"initialized"' | awk -F': ' '{print $2}' | tr -d ' ,')
  POD_SEALED=$(echo "$POD_STATUS" | grep '"sealed"' | awk -F': ' '{print $2}' | tr -d ' ,')
  if [[ "$POD_INITIALIZED" != "true" ]]; then
    echo "[ERROR] Pod $POD reports not initialized – cluster inconsistency. Aborting." >&2
    exit 1
  fi
  if [[ "$POD_SEALED" == "false" ]]; then
    echo "[INFO] Pod $POD already unsealed. Skipping."
    continue
  fi
  echo "[INFO] Unsealing $POD..."
  for ((i=0; i<THRESHOLD; i++)); do
    KEY=${UNSEAL_KEYS[$i]}
    kubectl exec -n "$NS" "$POD" -- vault operator unseal "$KEY" >/dev/null
  done
  echo "[INFO] $POD unsealed."
done

echo "[INFO] Verifying primary pod status:" 
kubectl exec -n "$NS" "$PRIMARY_POD" -- vault status

echo "[INFO] Root token (store securely, then remove from disk): $ROOT_TOKEN"
if [[ "$PRINT_KEYS" == "true" ]]; then
  echo "[WARN] Printing unseal keys to stdout (avoid in shared terminals):"
  for k in "${UNSEAL_KEYS[@]}"; do echo "UNSEAL_KEY: $k"; done
  echo "ROOT_TOKEN: $ROOT_TOKEN"
fi
echo "[HINT] To login: kubectl exec -n $NS -it $PRIMARY_POD -- vault login $ROOT_TOKEN"

echo "[DONE] Initialization/unseal workflow complete."
