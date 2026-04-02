#!/usr/bin/env bash
# pg-migrate.sh — Migrate a VSHNPostgreSQL claim from one cluster to another
# via kubectl exec + pg_dump | pg_restore (custom format).
#
# pg_dump and pg_restore run inside the database pods, so no local PostgreSQL
# installation is required. The postgres superuser connects via Unix socket
# (peer authentication) — no secrets or passwords are needed.
#
# The type of the source instance is detected (StackGres or CNPG) automatically. The destination
# is always assumed to be CNPG.
#
# Usage:
#   ./pg-migrate.sh \
#     --src-kubeconfig /path/to/src.kubeconfig \
#     --src-namespace  <claim-namespace> \
#     --src-claim      <claim-name> \
#     --dst-kubeconfig /path/to/dst.kubeconfig \   # omit if same cluster
#     --dst-namespace  <claim-namespace> \
#     --dst-claim      <claim-name> \
#     --cleanup-stackgres                          # optional: drop StackGres extensions after restore
#     --use-port-forward                          # optional: use port-forwarding instead of exec
#     --as-admin                                  # optional: impersonate system:admin for all kubectl calls

set -euo pipefail

# ----- Helper functions -----

log() { echo "[$(date +%T)] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

get_claim_field() {
  local kubeconfig=$1 namespace=$2 claim=$3 field=$4
  KUBECONFIG="$kubeconfig" kubectl get vshnpostgresql "$claim" \
    -n "$namespace" -o jsonpath="{$field}"
}

get_primary_pod() {
  local kubeconfig=$1 namespace=$2 label_selector=$3
  KUBECONFIG="$kubeconfig" kubectl get pod \
    -n "$namespace" -l "$label_selector" \
    -o jsonpath='{.items[0].metadata.name}'
}

cleanup_stackgres() {
  local kubeconfig=$1 namespace=$2 pod=$3 db=$4
  log "  Removing StackGres extensions and functions from database: $db"
  KUBECONFIG="$kubeconfig" kubectl "${KUBECTL_AS[@]}" exec -i -n "$namespace" "$pod" -- \
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

exec_restore() {
  log "Listing databases on source ($SRC_POD)..."
  DATABASES=$(KUBECONFIG="$SRC_KUBECONFIG" kubectl "${KUBECTL_AS[@]}" exec -n "$SRC_INSTANCE_NS" "$SRC_POD" -- \
    psql -U postgres -t -A -q -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false")
  [[ -n "$DATABASES" ]] || die "No databases found on source"
  log "  databases: $(echo "$DATABASES" | tr '\n' ' ')"

  while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    log "Migrating database: $db"
    KUBECONFIG="$SRC_KUBECONFIG" kubectl "${KUBECTL_AS[@]}" exec -n "$SRC_INSTANCE_NS" "$SRC_POD" -- \
      pg_dump \
        --username=postgres \
        --dbname="$db" \
        --no-password \
        --format=custom \
        --compress=0 \
        --lock-wait-timeout=120s \
    | KUBECONFIG="$DST_KUBECONFIG" kubectl "${KUBECTL_AS[@]}" exec -i -n "$DST_INSTANCE_NS" "$DST_POD" -- \
      pg_restore \
        --username=postgres \
        --dbname=postgres \
        --no-password \
        --clean \
        --if-exists \
        --verbose 2>&1 | tee -a "$RESTORE_LOG"
  done <<< "$DATABASES"
}

wait_for_port() {
  local port=$1 retries=30
  while ! nc -z 127.0.0.1 "$port" 2>/dev/null; do
    ((retries--)) || die "Port $port did not open in time."
    sleep 1
  done
}

read_secret_field() {
  local kubeconfig=$1 namespace=$2 secret=$3 key=$4
  KUBECONFIG="$kubeconfig" kubectl "${KUBECTL_AS[@]}" get secret "$secret" \
    -n "$namespace" -o jsonpath="{.data.$key}" | base64 -d
}

cleanup() {
  log "Cleaning up port-forwards..."
  [[ -n "${SRC_PF_PID:-}" ]] && kill "$SRC_PF_PID" 2>/dev/null || true
  [[ -n "${DST_PF_PID:-}" ]] && kill "$DST_PF_PID" 2>/dev/null || true
}


port_forward_restore() {
  trap cleanup EXIT
  # ----- Get secrets and instance namespaces -----

  log "Resolving source claim ($SRC_NAMESPACE/$SRC_CLAIM)..."
  SRC_SECRET=$(get_claim_field "$SRC_KUBECONFIG" "$SRC_NAMESPACE" "$SRC_CLAIM" \
                 '.spec.writeConnectionSecretToRef.name')
  SRC_INSTANCE_NS=$(get_claim_field "$SRC_KUBECONFIG" "$SRC_NAMESPACE" "$SRC_CLAIM" \
                 '.status.instanceNamespace')
  [[ -n "$SRC_SECRET" ]]      || die "Could not read .spec.writeConnectionSecretToRef.name from source claim"
  [[ -n "$SRC_INSTANCE_NS" ]] || die "Could not read .status.instanceNamespace from source claim"

  log "Resolving destination claim ($DST_NAMESPACE/$DST_CLAIM)..."
  DST_SECRET=$(get_claim_field "$DST_KUBECONFIG" "$DST_NAMESPACE" "$DST_CLAIM" \
                 '.spec.writeConnectionSecretToRef.name')
  DST_INSTANCE_NS=$(get_claim_field "$DST_KUBECONFIG" "$DST_NAMESPACE" "$DST_CLAIM" \
                 '.status.instanceNamespace')
  [[ -n "$DST_SECRET" ]]      || die "Could not read .spec.writeConnectionSecretToRef.name from destination claim"
  [[ -n "$DST_INSTANCE_NS" ]] || die "Could not read .status.instanceNamespace from destination claim"

  # ----- extract credentials from secrets -----
  # POSTGRESQL_HOST is a cluster-internal FQDN (<svc>.<ns>.svc.cluster.local).
  # We extract just the service name (first component) for port-forward use.

  log "Reading source credentials from secret '$SRC_SECRET'..."
  SRC_USER=$(read_secret_field "$SRC_KUBECONFIG" "$SRC_NAMESPACE" "$SRC_SECRET" 'POSTGRESQL_USER')
  SRC_PASS=$(read_secret_field "$SRC_KUBECONFIG" "$SRC_NAMESPACE" "$SRC_SECRET" 'POSTGRESQL_PASSWORD')
  SRC_DB=$(read_secret_field   "$SRC_KUBECONFIG" "$SRC_NAMESPACE" "$SRC_SECRET" 'POSTGRESQL_DB')
  SRC_SVC=$(read_secret_field  "$SRC_KUBECONFIG" "$SRC_NAMESPACE" "$SRC_SECRET" 'POSTGRESQL_HOST' \
            | cut -d. -f1)
  SRC_SVC_PORT=$(read_secret_field "$SRC_KUBECONFIG" "$SRC_NAMESPACE" "$SRC_SECRET" 'POSTGRESQL_PORT')

  log "Reading destination credentials from secret '$DST_SECRET'..."
  DST_USER=$(read_secret_field "$DST_KUBECONFIG" "$DST_NAMESPACE" "$DST_SECRET" 'POSTGRESQL_USER')
  DST_PASS=$(read_secret_field "$DST_KUBECONFIG" "$DST_NAMESPACE" "$DST_SECRET" 'POSTGRESQL_PASSWORD')
  DST_DB=$(read_secret_field   "$DST_KUBECONFIG" "$DST_NAMESPACE" "$DST_SECRET" 'POSTGRESQL_DB')
  DST_SVC=$(read_secret_field  "$DST_KUBECONFIG" "$DST_NAMESPACE" "$DST_SECRET" 'POSTGRESQL_HOST' \
            | cut -d. -f1)
  DST_SVC_PORT=$(read_secret_field "$DST_KUBECONFIG" "$DST_NAMESPACE" "$DST_SECRET" 'POSTGRESQL_PORT')

  SRC_LOCAL_PORT=15432
  DST_LOCAL_PORT=15433

  if [[ "$SRC_STACKGRES" == "true" ]]; then
    SRC_PF_TARGET="svc/primary-service"
  else
    SRC_PF_TARGET="svc/$SRC_SVC"
  fi

  for p in $SRC_LOCAL_PORT $DST_LOCAL_PORT; do
    nc -z 127.0.0.1 "$p" 2>/dev/null && die "Local port $p is already in use"
  done

  log "Port-forwarding source $SRC_PF_TARGET -> 127.0.0.1:$SRC_LOCAL_PORT..."
  KUBECONFIG="$SRC_KUBECONFIG" kubectl port-forward \
    -n "$SRC_INSTANCE_NS" "$SRC_PF_TARGET" \
    "${SRC_LOCAL_PORT}:${SRC_SVC_PORT}" &>/tmp/pf-src.log &
  SRC_PF_PID=$!

  log "Port-forwarding destination svc/$DST_SVC -> 127.0.0.1:$DST_LOCAL_PORT..."
  KUBECONFIG="$DST_KUBECONFIG" kubectl port-forward \
    -n "$DST_INSTANCE_NS" "svc/$DST_SVC" \
    "${DST_LOCAL_PORT}:${DST_SVC_PORT}" &>/tmp/pf-dst.log &
  DST_PF_PID=$!

  log "Waiting for port-forwards to be ready..."
  wait_for_port "$SRC_LOCAL_PORT"
  wait_for_port "$DST_LOCAL_PORT"
  log "Port-forwards ready."

  # ----- List source databases -----
  log "Listing databases on source (via port-forward)..."
  DATABASES=$(PGPASSWORD="$SRC_PASS" PGSSLMODE=disable psql \
    --host=127.0.0.1 \
    --port="$SRC_LOCAL_PORT" \
    --username="$SRC_USER" \
    -t -A -q -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false")
  [[ -n "$DATABASES" ]] || die "No databases found on source"
  log "  databases: $(echo "$DATABASES" | tr '\n' ' ')"

  # ----- Dump + Restore -----
  # sslmode=disable: kubectl port-forward wraps traffic in a plain TCP tunnel;
  # PostgreSQL's TLS handshake is unreliable through it.
  # --format=custom: binary format, faster than plain SQL and supports streaming.

  log "Streaming pg_dump | pg_restore..."
  PGPASSWORD="$SRC_PASS" PGSSLMODE=disable pg_dump \
    --host=127.0.0.1 \
    --port="$SRC_LOCAL_PORT" \
    --username="$SRC_USER" \
    --dbname="$SRC_DB" \
    --no-password \
    --format=custom \
    --compress=0 \
    --lock-wait-timeout=120s \
  | PGPASSWORD="$DST_PASS" PGSSLMODE=disable pg_restore \
    --host=127.0.0.1 \
    --port="$DST_LOCAL_PORT" \
    --username="$DST_USER" \
    --dbname="$DST_DB" \
    --no-password \
    --clean \
    --if-exists \
    --single-transaction \
    --verbose 2>&1 | tee /tmp/pg-restore.log

}

# ----- Argument parsing -----

SRC_KUBECONFIG=""
SRC_NAMESPACE=""
SRC_CLAIM=""
DST_KUBECONFIG=""
DST_NAMESPACE=""
DST_CLAIM=""
CLEANUP_STACKGRES=false
USE_PORT_FORWARD=false
KUBECTL_AS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --src-kubeconfig)    SRC_KUBECONFIG=$2;    shift 2 ;;
    --src-namespace)     SRC_NAMESPACE=$2;     shift 2 ;;
    --src-claim)         SRC_CLAIM=$2;         shift 2 ;;
    --dst-kubeconfig)    DST_KUBECONFIG=$2;    shift 2 ;;
    --dst-namespace)     DST_NAMESPACE=$2;     shift 2 ;;
    --dst-claim)         DST_CLAIM=$2;         shift 2 ;;
    --use-port-forward)  USE_PORT_FORWARD=true; shift ;;
    --cleanup-stackgres) CLEANUP_STACKGRES=true; shift ;;
    --as-admin)          KUBECTL_AS=(--as system:admin); shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$SRC_KUBECONFIG" ]] || die "--src-kubeconfig is required"
[[ -n "$SRC_NAMESPACE" ]]  || die "--src-namespace is required"
[[ -n "$SRC_CLAIM" ]]      || die "--src-claim is required"
[[ -n "$DST_NAMESPACE" ]]  || die "--dst-namespace is required"
[[ -n "$DST_CLAIM" ]]      || die "--dst-claim is required"

# If no destination kubeconfig is provided, assume the same cluster
DST_KUBECONFIG="${DST_KUBECONFIG:-$SRC_KUBECONFIG}"

command -v kubectl &>/dev/null || die "'kubectl' not found in PATH."

# ----- Get instance namespaces -----

log "Resolving source claim ($SRC_NAMESPACE/$SRC_CLAIM)..."
SRC_INSTANCE_NS=$(get_claim_field "$SRC_KUBECONFIG" "$SRC_NAMESPACE" "$SRC_CLAIM" \
               '.status.instanceNamespace')
[[ -n "$SRC_INSTANCE_NS" ]] || die "Could not read .status.instanceNamespace from source claim"

log "Resolving destination claim ($DST_NAMESPACE/$DST_CLAIM)..."
DST_INSTANCE_NS=$(get_claim_field "$DST_KUBECONFIG" "$DST_NAMESPACE" "$DST_CLAIM" \
               '.status.instanceNamespace')
[[ -n "$DST_INSTANCE_NS" ]] || die "Could not read .status.instanceNamespace from destination claim"

# ----- Detect source instance type and find primary pods -----
SRC_STACKGRES=false

log "Detecting source instance type in $SRC_INSTANCE_NS..."
if KUBECONFIG="$SRC_KUBECONFIG" kubectl get svc primary-service \
    -n "$SRC_INSTANCE_NS" &>/dev/null; then
  log "  detected: StackGres -- looking for pod with role=primary"
  SRC_POD=$(get_primary_pod "$SRC_KUBECONFIG" "$SRC_INSTANCE_NS" "role=primary")
  SRC_STACKGRES=true
else
  log "  detected: CNPG -- looking for pod with cnpg.io/instanceRole=primary"
  SRC_POD=$(get_primary_pod "$SRC_KUBECONFIG" "$SRC_INSTANCE_NS" "cnpg.io/instanceRole=primary")
fi
[[ -n "$SRC_POD" ]] || die "Could not find primary pod in $SRC_INSTANCE_NS"
log "  source pod: $SRC_POD"

log "Finding destination primary pod in $DST_INSTANCE_NS..."
DST_POD=$(get_primary_pod "$DST_KUBECONFIG" "$DST_INSTANCE_NS" "cnpg.io/instanceRole=primary")
[[ -n "$DST_POD" ]] || die "Could not find primary pod in $DST_INSTANCE_NS"
log "  destination pod: $DST_POD"

log "  source      : postgres@$SRC_POD  (instance ns: $SRC_INSTANCE_NS)"
log "  destination : postgres@$DST_POD  (instance ns: $DST_INSTANCE_NS)"

# ----- Dump + Restore -----
# pg_dump runs inside the source pod and streams via kubectl exec to pg_restore
# in the destination pod.

RESTORE_LOG=/tmp/pg-restore.log
> "$RESTORE_LOG"

if [[ "$USE_PORT_FORWARD" == "true" ]]; then
  port_forward_restore
else
  exec_restore
fi


if [[ "$CLEANUP_STACKGRES" == "true" ]]; then
  log "Cleaning up StackGres extensions and functions on destination..."
  while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    cleanup_stackgres "$DST_KUBECONFIG" "$DST_INSTANCE_NS" "$DST_POD" "$db"
  done <<< "$DATABASES"

  log "Removing plpython3u from destination claim ($DST_NAMESPACE/$DST_CLAIM)..."
  # grep -n returns 1-based line numbers; JSON patch paths are 0-based.
  PLPYTHON3U_LINE=$(KUBECONFIG="$DST_KUBECONFIG" kubectl get vshnpostgresql "$DST_CLAIM" \
    -n "$DST_NAMESPACE" \
    -o jsonpath='{range .spec.parameters.service.extensions[*]}{.name}{"\n"}{end}' \
    | grep -n 'plpython3u' | cut -d: -f1)
  if [[ -n "$PLPYTHON3U_LINE" ]]; then
    PLPYTHON3U_INDEX=$(( PLPYTHON3U_LINE - 1 ))
    KUBECONFIG="$DST_KUBECONFIG" kubectl "${KUBECTL_AS[@]}" patch vshnpostgresql "$DST_CLAIM" \
      -n "$DST_NAMESPACE" \
      --type=json \
      -p="[{\"op\": \"remove\", \"path\": \"/spec/parameters/service/extensions/$PLPYTHON3U_INDEX\"}]"
    log "  Done."
  else
    log "  plpython3u not found in destination claim extensions, skipping."
  fi
fi

log "Checking for errors..."
# pg_restore emits "error:" lines for pre-existing missing objects even with
# `--if-exists`. We therefore filter those errors out.
if grep -E '^pg_restore: error:' "$RESTORE_LOG" \
   | grep -qv 'does not exist'; then
  log "WARNING: errors detected -- review $RESTORE_LOG"
else
  log "Restore finished successfully."
fi

log "Done: $SRC_NAMESPACE/$SRC_CLAIM -> $DST_NAMESPACE/$DST_CLAIM"
