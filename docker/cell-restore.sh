#!/usr/bin/env bash
# Restore a cell from an archive made by the chart's backup (scripts/cell-backup.sh): the cell's Secrets, then the
# platform and Keycloak databases. See docs/backup-restore.md for the full runbook.
#   scripts/cell-restore.sh -r acme -n tenant-acme acme-20261009T021700Z.tar.gz          # secrets + databases
#   scripts/cell-restore.sh -r acme -n tenant-acme --secrets-only ARCHIVE                 # new cluster: before helm install
#   scripts/cell-restore.sh -r acme -n tenant-acme --databases-only ARCHIVE               # … after helm install
#   scripts/cell-restore.sh --compose [DIR] [--yes] [--secrets-only|--databases-only] ARCHIVE  # Docker Compose cell
# Databases: the API, worker, managed runners and Keycloak are scaled to 0 while each database is dropped and recreated
# from its dump inside the postgres pod, then scaled back. Needs kubectl (or docker for --compose); --yes/-y skips the
# confirmation (scripts, CI). A Compose restore works into a running fresh cell: it aligns the Postgres role with the
# restored password, restarts the cell and waits for every container to be healthy.
set -euo pipefail
RELEASE="${RELEASE:-}"; NAMESPACE="${NAMESPACE:-}"; MODE=all; YES=0; ARCHIVE=""; COMPOSE=""
# shellcheck source=scripts/lib/compose.sh
source "$(dirname "$0")/lib/compose.sh"
usage() { sed -n '2,9p' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--release) RELEASE="$2"; shift 2;;
    -n|--namespace) NAMESPACE="$2"; shift 2;;
    --secrets-only) MODE=secrets; shift;;
    --databases-only) MODE=databases; shift;;
    -y|--yes) YES=1; shift;;
    --compose) COMPOSE="."; if [ $# -gt 1 ] && [ "${2#-}" = "$2" ] && [ -d "$2" ]; then COMPOSE="$2"; shift; fi; shift;;
    -h|--help) usage;;
    -*) echo "unknown argument: $1" >&2; usage 1;;
    *) ARCHIVE="$1"; shift;;
  esac
done
if [ -n "$COMPOSE" ]; then [ -n "$ARCHIVE" ] || { echo "the archive is required" >&2; usage 1; }; compose_restore "$COMPOSE" "$ARCHIVE" "$MODE" "$YES"; exit $?; fi
[ -n "$RELEASE" ] && [ -n "$NAMESPACE" ] && [ -n "$ARCHIVE" ] || { echo "--release, --namespace and the archive are required (or --compose for a Docker Compose cell)" >&2; usage 1; }
[ -f "$ARCHIVE" ] || { echo "no such file: $ARCHIVE" >&2; exit 1; }
K=(kubectl -n "$NAMESPACE")

# ---- unpack and check ------------------------------------------------------------------------
if [ -f "$ARCHIVE.sha256" ]; then ( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" ); fi
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
tar -xzf "$ARCHIVE" -C "$WORK"
ROOT="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -f "$ROOT/manifest.txt" ] || { echo "not a cell backup (no manifest.txt)" >&2; exit 1; }
echo "archive:"; sed 's/^/  /' "$ROOT/manifest.txt"
CELL="$(sed -n 's/^cell=//p' "$ROOT/manifest.txt")"
if [ "$YES" != 1 ]; then
  echo; echo "This restores cell '$CELL' into release '$RELEASE' in namespace '$NAMESPACE' ($MODE). Existing data there is replaced."
  read -r -p "Continue? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || exit 1
fi

# ---- secrets ---------------------------------------------------------------------------------
# Recreated by name from the archive's files, with Helm's ownership metadata so a later `helm install` / `upgrade`
# adopts them instead of failing on "already exists" (and its lookup-reuse keeps their values).
if [ "$MODE" != databases ]; then
  for dir in "$ROOT"/secrets/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    case "$name" in "$RELEASE-"*) ;; *) name="$RELEASE-$name";; esac   # a Compose archive names secrets without the release prefix
    # server-side apply: Helm-created Secrets have no last-applied annotation, so a client-side apply warns on each
    "${K[@]}" create secret generic "$name" --from-file="$dir" --dry-run=client -o yaml \
      | "${K[@]}" apply --server-side --force-conflicts --field-manager=cell-restore -f - > /dev/null
    "${K[@]}" label secret "$name" app.kubernetes.io/managed-by=Helm --overwrite > /dev/null
    "${K[@]}" annotate secret "$name" "meta.helm.sh/release-name=$RELEASE" "meta.helm.sh/release-namespace=$NAMESPACE" --overwrite > /dev/null
    echo "secret $name restored ($(ls "$dir" | tr '\n' ' '))"
  done
  [ "$MODE" = secrets ] && { echo "secrets done. Now install the release (make deploy TENANT=$RELEASE), then run again with --databases-only."; exit 0; }
fi

# ---- databases -------------------------------------------------------------------------------
PG_POD="$RELEASE-postgres-0"
"${K[@]}" get pod "$PG_POD" > /dev/null 2>&1 || {
  echo "no bundled postgres pod $PG_POD: restore the dumps into the external server yourself:" >&2
  echo "  PGHOST=… PGUSER=… PGPASSWORD=… deploy/helm/secops-cell/files/restore-db.sh $ROOT/db   (with the API, worker and Keycloak stopped)" >&2
  exit 1
}
# which workloads exist and how many replicas they run, to put them back afterwards
SCALED=()
for w in "deployment/$RELEASE-api" "deployment/$RELEASE-worker" "deployment/$RELEASE-keycloak" "statefulset/$RELEASE-runner"; do
  n="$("${K[@]}" get "$w" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  [ -n "$n" ] && SCALED+=("$w=$n")
done
restore_scale() { for e in "${SCALED[@]}"; do "${K[@]}" scale "${e%=*}" --replicas="${e#*=}" > /dev/null; done; }
echo "stopping ${SCALED[*]%=*}"
for e in "${SCALED[@]}"; do "${K[@]}" scale "${e%=*}" --replicas=0 > /dev/null; done
trap 'restore_scale; rm -rf "$WORK"' EXIT
for e in "${SCALED[@]}"; do
  w="${e%=*}"
  "${K[@]}" rollout status "$w" --timeout=180s > /dev/null 2>&1 || true
done
# nothing of the cell may still hold a connection
"${K[@]}" wait --for=delete pod -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name in (api,worker,keycloak,runner)" --timeout=180s > /dev/null 2>&1 || true

echo "copying dumps into $PG_POD"
"${K[@]}" exec "$PG_POD" -- sh -c 'rm -rf /tmp/restore && mkdir -p /tmp/restore'
"${K[@]}" cp "$ROOT/db/." "$PG_POD:/tmp/restore/"
# restore-db.sh ships with the chart: deploy/helm/secops-cell (platform checkout) or charts/secops-cell (matelot-cloud/helm-charts)
RESTORE_DB=""; for d in "${CHART_DIR:-}" "$(dirname "$0")/../deploy/helm/secops-cell" "$(dirname "$0")/../charts/secops-cell"; do [ -n "$d" ] && [ -f "$d/files/restore-db.sh" ] && { RESTORE_DB="$d/files/restore-db.sh"; break; }; done
[ -n "$RESTORE_DB" ] || { echo "restore-db.sh not found next to this script (set CHART_DIR to the secops-cell chart folder)" >&2; exit 1; }
"${K[@]}" cp "$RESTORE_DB" "$PG_POD:/tmp/restore/restore-db.sh"
"${K[@]}" exec "$PG_POD" -- sh -c 'set -e; PGHOST=localhost PGUSER="$POSTGRES_USER" PGPASSWORD="$POSTGRES_PASSWORD" bash /tmp/restore/restore-db.sh /tmp/restore; rm -rf /tmp/restore'

echo "starting ${SCALED[*]%=*}"
restore_scale
trap 'rm -rf "$WORK"' EXIT
"${K[@]}" rollout status "deployment/$RELEASE-api" --timeout=600s
echo "restore done: cell '$CELL' from $(basename "$ARCHIVE")"
echo "check: scripts/smoke.sh against the cell, and that connections / registries still decrypt (Connections page: no 'cannot decrypt' errors)"
