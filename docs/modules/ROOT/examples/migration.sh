#!/usr/bin/env bash
# pg-migrate.sh — Migrate a VSHNPostgreSQL claim to another within the same namespace
# via a temporary migration pod running pg_dump | pg_restore (custom format).
#
# The migration pod is created in the claim namespace where the connection secrets
# already live. It streams pg_dump directly into pg_restore inside the cluster,
# avoiding port-forwarding and making it reliable for large databases.
#
# Usage:
#   ./pg-migrate.sh \
#     --namespace    <claim-namespace> \
#     --src-claim    <source-claim-name> \
#     --dst-claim    <destination-claim-name> \
#     [--kubeconfig  /path/to/kubeconfig] \
#     [--image       <postgres-image>]    # default: ghcr.io/cloudnative-pg/postgresql:18
#     [--cleanup-stackgres]               # optional: drop StackGres extensions after restore
#     [--as-admin]                        # impersonate system:admin

set -euo pipefail

# ----- Helpers -----

log() { echo "[$(date +%T)] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ----- Helpers StackGres cleanup -----

get_primary_pod() {
  local namespace=$1 label_selector=$2
  kubectl "${KUBECTL_AS[@]}" get pod \
    -n "$namespace" -l "$label_selector" \
    -o jsonpath='{.items[0].metadata.name}'
}

do_cleanup_stackgres() {
  local namespace=$1 pod=$2 db=$3
  log "  Removing StackGres extensions and functions from database: $db"
  kubectl "${KUBECTL_AS[@]}" exec -i -n "$namespace" "$pod" -- \
    psql -U postgres -d "$db" -q <<'EOSQL'
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT n.nspname AS schema,
           p.proname AS name,
           pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpython3u')
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %I.%I(%s)', r.schema, r.name, r.args);
  END LOOP;
END;
$$;
DROP EXTENSION IF EXISTS plpython3u;
EOSQL
}

# ----- Cleanup -----

_MIGRATION_POD=""

cleanup_pod() {
  [[ -z "$_MIGRATION_POD" ]] && return 0
  log "Cleaning up migration pod '$_MIGRATION_POD'..."
  kubectl "${KUBECTL_AS[@]}" delete pod "$_MIGRATION_POD" \
    -n "$NAMESPACE" --ignore-not-found &>/dev/null || true
}

# ----- Argument parsing -----

NAMESPACE=""
SRC_CLAIM=""
DST_CLAIM=""
IMAGE="ghcr.io/cloudnative-pg/postgresql:18"
CLEANUP_STACKGRES=false
KUBECTL_AS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)         NAMESPACE=$2;  shift 2 ;;
    --src-claim)         SRC_CLAIM=$2;  shift 2 ;;
    --dst-claim)         DST_CLAIM=$2;  shift 2 ;;
    --kubeconfig)        export KUBECONFIG=$2; shift 2 ;;
    --image)             IMAGE=$2;      shift 2 ;;
    --cleanup-stackgres) CLEANUP_STACKGRES=true; shift ;;
    --as-admin)          KUBECTL_AS=(--as system:admin); shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$NAMESPACE" ]] || die "--namespace is required"
[[ -n "$SRC_CLAIM" ]] || die "--src-claim is required"
[[ -n "$DST_CLAIM" ]] || die "--dst-claim is required"

command -v kubectl &>/dev/null || die "'kubectl' not found in PATH."

# ----- Resolve connection secrets -----

log "Resolving source claim ($NAMESPACE/$SRC_CLAIM)..."
SRC_SECRET=$(kubectl "${KUBECTL_AS[@]}" get vshnpostgresql "$SRC_CLAIM" \
  -n "$NAMESPACE" -o jsonpath='{.spec.writeConnectionSecretToRef.name}')
[[ -n "$SRC_SECRET" ]] || die "Could not read .spec.writeConnectionSecretToRef.name from source claim"

log "Resolving destination claim ($NAMESPACE/$DST_CLAIM)..."
DST_SECRET=$(kubectl "${KUBECTL_AS[@]}" get vshnpostgresql "$DST_CLAIM" \
  -n "$NAMESPACE" -o jsonpath='{.spec.writeConnectionSecretToRef.name}')
[[ -n "$DST_SECRET" ]] || die "Could not read .spec.writeConnectionSecretToRef.name from destination claim"

log "  source secret      : $SRC_SECRET"
log "  destination secret : $DST_SECRET"

# ----- Create migration pod -----

RESTORE_LOG=/tmp/pg-restore.log
> "$RESTORE_LOG"

MIGRATION_POD="pg-migration-$(date +%s)"
_MIGRATION_POD="$MIGRATION_POD"
trap cleanup_pod EXIT

log "Creating migration pod '$MIGRATION_POD' (image: $IMAGE)..."
# The inline shell script uses envFrom-injected variables with prefixes:
#   SRC_POSTGRESQL_{HOST,PORT,USER,PASSWORD,DB}  (from source connection secret)
#   DST_POSTGRESQL_{HOST,PORT,USER,PASSWORD,DB}  (from destination connection secret)
# All $-signs are escaped (\$) so bash does not expand them during heredoc
# processing; they reach the pod shell as literal $.
kubectl "${KUBECTL_AS[@]}" apply -f - <<EOYAML
apiVersion: v1
kind: Pod
metadata:
  name: ${MIGRATION_POD}
  namespace: ${NAMESPACE}
  labels:
    app: pg-migration
spec:
  restartPolicy: Never
  containers:
  - name: migrate
    image: ${IMAGE}
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      runAsNonRoot: true
      seccompProfile:
        type: RuntimeDefault
    command:
    - /bin/bash
    - -c
    - |
      set -euo pipefail
      echo "[INFO] Listing source databases..."
      DATABASES=\$(PGPASSWORD="\${SRC_POSTGRESQL_PASSWORD}" psql \\
        --host="\${SRC_POSTGRESQL_HOST}" \\
        --port="\${SRC_POSTGRESQL_PORT}" \\
        --username="\${SRC_POSTGRESQL_USER}" \\
        -t -A -q -c "SELECT datname FROM pg_database WHERE datistemplate = false")
      [ -n "\$DATABASES" ] || { echo "[ERROR] No databases found on source"; exit 1; }
      echo "[INFO] Databases: \$(echo "\$DATABASES" | tr '\\n' ' ')"
      for db in \$DATABASES; do
        echo "[INFO] Migrating database: \$db"
        PGPASSWORD="\${SRC_POSTGRESQL_PASSWORD}" pg_dump \\
          --host="\${SRC_POSTGRESQL_HOST}" \\
          --port="\${SRC_POSTGRESQL_PORT}" \\
          --username="\${SRC_POSTGRESQL_USER}" \\
          --dbname="\$db" \\
          --no-password \\
          --format=custom \\
          --compress=0 \\
          --lock-wait-timeout=120s \\
        | PGPASSWORD="\${DST_POSTGRESQL_PASSWORD}" pg_restore \\
          --host="\${DST_POSTGRESQL_HOST}" \\
          --port="\${DST_POSTGRESQL_PORT}" \\
          --username="\${DST_POSTGRESQL_USER}" \\
          --dbname="\${DST_POSTGRESQL_DB}" \\
          --no-password \\
          --clean \\
          --if-exists \\
          --verbose
      done
      echo "[INFO] Migration complete."
    envFrom:
    - secretRef:
        name: ${SRC_SECRET}
      prefix: SRC_
    - secretRef:
        name: ${DST_SECRET}
      prefix: DST_
EOYAML

log "Waiting for migration pod to start (up to 120s)..."
for i in $(seq 1 24); do
  PHASE=$(kubectl "${KUBECTL_AS[@]}" get pod "$MIGRATION_POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  case "$PHASE" in
    Running|Succeeded|Failed) break ;;
  esac
  [[ $i -eq 24 ]] && die "Migration pod did not start within 120s (phase: ${PHASE:-unknown})"
  log "  phase: ${PHASE:-unknown} — waiting..."
  sleep 5
done

log "Streaming migration pod logs..."
kubectl "${KUBECTL_AS[@]}" logs -f "$MIGRATION_POD" \
  -n "$NAMESPACE" | tee "$RESTORE_LOG" || true

# ----- Check result -----

log "Waiting for migration pod to reach terminal state..."
for i in $(seq 1 60); do
  POD_PHASE=$(kubectl "${KUBECTL_AS[@]}" get pod "$MIGRATION_POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  case "$POD_PHASE" in
    Succeeded|Failed) break ;;
  esac
  [[ $i -eq 60 ]] && die "Migration pod did not finish within 5m after log stream ended (phase: ${POD_PHASE:-unknown})"
  sleep 5
done

[[ "$POD_PHASE" == "Succeeded" ]] || die "Migration pod did not succeed (phase: $POD_PHASE) — check logs above"

log "Checking for errors..."
# pg_restore emits "error:" lines for pre-existing missing objects even with
# --if-exists. We therefore filter those out.
if grep -E '^pg_restore: error:' "$RESTORE_LOG" \
   | grep -qv 'does not exist'; then
  log "WARNING: errors detected — review $RESTORE_LOG"
else
  log "Restore finished successfully."
fi

if [[ "$CLEANUP_STACKGRES" == "true" ]]; then
  log "Resolving destination instance namespace..."
  DST_INSTANCE_NS=$(kubectl "${KUBECTL_AS[@]}" get vshnpostgresql "$DST_CLAIM" \
    -n "$NAMESPACE" -o jsonpath='{.status.instanceNamespace}')
  [[ -n "$DST_INSTANCE_NS" ]] || die "Could not read .status.instanceNamespace from destination claim"

  log "Finding destination primary pod in $DST_INSTANCE_NS..."
  DST_POD=$(get_primary_pod "$DST_INSTANCE_NS" "cnpg.io/instanceRole=primary")
  [[ -n "$DST_POD" ]] || die "Could not find primary pod in $DST_INSTANCE_NS"
  log "  destination pod: $DST_POD"

  log "Listing databases on destination..."
  DATABASES=$(kubectl "${KUBECTL_AS[@]}" exec -n "$DST_INSTANCE_NS" "$DST_POD" -- \
    psql -U postgres -t -A -q -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false")
  [[ -n "$DATABASES" ]] || die "No databases found on destination"

  log "Cleaning up StackGres extensions on destination..."
  while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    do_cleanup_stackgres "$DST_INSTANCE_NS" "$DST_POD" "$db"
  done <<< "$DATABASES"

  log "Removing plpython3u from destination claim ($NAMESPACE/$DST_CLAIM)..."
  PLPYTHON3U_LINE=$(kubectl "${KUBECTL_AS[@]}" get vshnpostgresql "$DST_CLAIM" \
    -n "$NAMESPACE" \
    -o jsonpath='{range .spec.parameters.service.extensions[*]}{.name}{"\n"}{end}' \
    | grep -n 'plpython3u' | cut -d: -f1)
  if [[ -n "$PLPYTHON3U_LINE" ]]; then
    PLPYTHON3U_INDEX=$(( PLPYTHON3U_LINE - 1 ))
    kubectl "${KUBECTL_AS[@]}" patch vshnpostgresql "$DST_CLAIM" \
      -n "$NAMESPACE" \
      --type=json \
      -p="[{\"op\": \"remove\", \"path\": \"/spec/parameters/service/extensions/$PLPYTHON3U_INDEX\"}]"
    log "  Done."
  else
    log "  plpython3u not found in destination claim extensions, skipping."
  fi
fi

log "Done: $NAMESPACE/$SRC_CLAIM -> $NAMESPACE/$DST_CLAIM"
