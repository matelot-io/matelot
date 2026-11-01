#!/usr/bin/env bash
# Run a cell backup now (from the chart's CronJob) and optionally download the archive from the backups PVC.
#   scripts/cell-backup.sh -r acme -n tenant-acme                 # run now, wait, print the log
#   scripts/cell-backup.sh -r acme -n tenant-acme -d ./backups    # … and copy the newest archive (+ .sha256) to ./backups
#   scripts/cell-backup.sh -r acme -n tenant-acme --list          # archives on the PVC
#   scripts/cell-backup.sh --compose [DIR] [-d ./backups] [--list] # Docker Compose cell (DIR = folder with compose.yaml, default .)
# Needs: kubectl with access to the namespace; backup.enabled=true in the release. See docs/backup-restore.md.
set -euo pipefail
RELEASE="${RELEASE:-}"; NAMESPACE="${NAMESPACE:-}"; DOWNLOAD=""; LIST=0; TIMEOUT="${TIMEOUT:-1800}"; COMPOSE=""
# shellcheck source=scripts/lib/wait.sh
source "$(dirname "$0")/lib/wait.sh"
# shellcheck source=scripts/lib/compose.sh
source "$(dirname "$0")/lib/compose.sh"
usage() { sed -n '2,8p' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--release) RELEASE="$2"; shift 2;;
    -n|--namespace) NAMESPACE="$2"; shift 2;;
    -d|--download) DOWNLOAD="$2"; shift 2;;
    --list) LIST=1; shift;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --compose) COMPOSE="."; if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then COMPOSE="$2"; shift; fi; shift;;
    -h|--help) usage;;
    *) echo "unknown argument: $1" >&2; usage 1;;
  esac
done
if [ -n "$COMPOSE" ]; then compose_backup "$COMPOSE" "$DOWNLOAD" "$LIST"; exit $?; fi
[ -n "$RELEASE" ] && [ -n "$NAMESPACE" ] || { echo "--release and --namespace are required (or --compose for a Docker Compose cell)" >&2; usage 1; }
K=(kubectl -n "$NAMESPACE")
"${K[@]}" get cronjob "$RELEASE-backup" > /dev/null || { echo "no CronJob $RELEASE-backup in $NAMESPACE: set backup.enabled=true and upgrade the release" >&2; exit 1; }

# A throw-away pod with the backups PVC mounted, for --list and --download.
HELPER_POD=""
cleanup_helper() { [ -n "$HELPER_POD" ] && "${K[@]}" delete pod "$HELPER_POD" --wait=false > /dev/null 2>&1 || true; }
helper() { # helper <command…>
  local pod="$RELEASE-backup-reader-$$"
  HELPER_POD="$pod"; trap cleanup_helper EXIT
  local image; image="$("${K[@]}" get cronjob "$RELEASE-backup" -o jsonpath='{.spec.jobTemplate.spec.template.spec.initContainers[0].image} {.spec.jobTemplate.spec.template.spec.containers[0].image}' | awk '{print $1}')"
  "${K[@]}" run "$pod" --image="$image" --restart=Never --quiet --overrides="$(cat <<EOF
{"spec":{"securityContext":{"runAsUser":999,"runAsNonRoot":true,"fsGroup":999},
 "containers":[{"name":"reader","image":"$image","command":["sleep","3600"],
   "volumeMounts":[{"name":"backups","mountPath":"/backups","readOnly":true}]}],
 "volumes":[{"name":"backups","persistentVolumeClaim":{"claimName":"$RELEASE-backups"}}]}}
EOF
)" > /dev/null
  "${K[@]}" wait --for=condition=Ready "pod/$pod" --timeout=120s > /dev/null
  "$@" "$pod"
}

if [ "$LIST" = 1 ]; then
  list() { "${K[@]}" exec "$1" -- sh -c 'ls -lh /backups | grep -v "^total"'; }
  helper list
  exit 0
fi

JOB="$RELEASE-backup-manual-$(date -u +%Y%m%d%H%M%S)"
echo "starting backup job $JOB"
"${K[@]}" create job "$JOB" --from="cronjob/$RELEASE-backup" > /dev/null
if ! wait_job "$NAMESPACE" "$JOB" "$TIMEOUT"; then
  echo "backup job did not complete; log:" >&2
  "${K[@]}" logs "job/$JOB" --all-containers=true >&2 || true
  exit 1
fi
"${K[@]}" logs "job/$JOB" --all-containers=true | sed 's/^/  /'

if [ -n "$DOWNLOAD" ]; then
  mkdir -p "$DOWNLOAD"
  fetch() {
    local pod="$1" name
    name="$("${K[@]}" exec "$pod" -- sh -c 'basename "$(readlink -f /backups/latest.tar.gz)"')"
    # streamed with cat rather than `kubectl cp`: no tar in the path (and none of its "Removing leading /" notes);
    # the checksum below verifies the transfer
    "${K[@]}" exec "$pod" -- cat "/backups/$name" > "$DOWNLOAD/$name"
    "${K[@]}" exec "$pod" -- cat "/backups/$name.sha256" > "$DOWNLOAD/$name.sha256"
    ( cd "$DOWNLOAD" && sha256sum -c "$name.sha256" )
    echo "downloaded $DOWNLOAD/$name"
  }
  helper fetch
fi
