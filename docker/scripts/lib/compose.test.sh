#!/usr/bin/env bash
# Unit test of the Compose backup/restore helpers without Docker: a `docker` shim on PATH runs the `sh -c` script that
# compose.sh hands to `compose run` locally, with the container paths mapped to a temp dir. It checks what broke in CI:
# the copy-out of an archive and the copy-in of secrets never bind-mount a host directory (they stream through stdout /
# stdin), the sha256 is verified after the copy, and the restore reaches compose-init.sh's restore-secrets mode.
# Runs as whoever invokes it (CI: the unprivileged runner user). Run: bash scripts/lib/compose.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/backups" "$T/project" "$T/config" "$T/registry"
touch "$T/project/compose.yaml"
export FAKE_ROOT="$T" PATH="$T/bin:$PATH" LOG="$T/docker.log"
# the shim: records every invocation; for `run … --entrypoint sh <service> -c SCRIPT [sh ARGS…]` runs SCRIPT with container
# paths rewritten (/backups, /tmp/restore, /init/compose-init.sh, /var/lib/registry); refuses bind mounts (-v) — that was the bug
cat > "$T/bin/docker" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$LOG"; echo >> "$LOG"
for a in "$@"; do [ "$a" = "-v" ] && { echo "shim: bind mount used ($*)" >&2; exit 97; }; done
[ "${1:-}" = compose ] || { echo "shim: expected docker compose, got $*" >&2; exit 98; }
shift
sub=""; script=""; svc=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    run) sub=run; shift; continue;;
    -c) script="$2"; shift 2; args=("$@"); break;;
    --entrypoint) shift 2; svc="$1"; shift; continue;;
    ps) cat "${FAKE_PS:-/dev/null}"; exit 0;;
    up|stop|exec|cp) echo "shim: $1 $2 not simulated"; exit 0;;
  esac; shift
done
[ "$sub" = run ] || { echo "shim: unexpected: $*" >&2; exit 99; }
[ -n "$script" ] || { echo "shim: run $svc (no script) not simulated"; exit 0; }
case "$script" in *"-T "*) ;; esac
script="${script//\/backups/$FAKE_ROOT/backups}"
script="${script//\/tmp\/restore/$FAKE_ROOT/restore}"
script="${script//\/init\/compose-init.sh/$FAKE_ROOT/compose-init.sh}"
script="${script//\/var\/lib\/registry/$FAKE_ROOT/registry}"
[ -z "${FAKE_REGISTRY_TRUNCATE:-}" ] || script="${script//tar -C/tar --exclude='*sha256-2' -C}"   # simulates a short extraction
export MATELOT_CONFIG_DIR="$FAKE_ROOT/config" MATELOT_VOLUMES_DIR="$FAKE_ROOT/volumes"
exec sh -c "$script" "${args[@]}"
SHIM
chmod +x "$T/bin/docker"
# compose-init.sh: deploy/compose/init in the platform checkout, ../../init in the published docker/ folder
INIT="$HERE/../../deploy/compose/init/compose-init.sh"; [ -f "$INIT" ] || INIT="$HERE/../../init/compose-init.sh"
cp "$INIT" "$T/compose-init.sh"
# shellcheck source=compose.sh
. "$HERE/compose.sh"

# 1. an archive in the "backups volume" with latest.tar.gz pointing at it
mkdir -p "$T/src/main-x/secrets/cell-key" "$T/src/main-x/db"; printf 'k3y' > "$T/src/main-x/secrets/cell-key/CELL_ENCRYPTION_KEY"; echo "cell: main" > "$T/src/main-x/manifest.txt"
tar -C "$T/src" -czf "$T/backups/main-x.tar.gz" main-x
( cd "$T/backups" && sha256sum main-x.tar.gz > main-x.tar.gz.sha256 && ln -s main-x.tar.gz latest.tar.gz )

# 2. copy-out: streamed, verified, printed with the host path
out="$(compose_download "$T/down")"
case "$out" in "downloaded $T/down/main-x.tar.gz ("*"sha256 "*) ;; *) echo "FAIL: download message: $out" >&2; exit 1;; esac
cmp "$T/backups/main-x.tar.gz" "$T/down/main-x.tar.gz" || { echo "FAIL: archive differs after the copy" >&2; exit 1; }
grep -q -- ' -T ' "$LOG" || { echo "FAIL: compose run without -T (a TTY would corrupt the stream)" >&2; exit 1; }
# a corrupted copy is caught
cp "$T/backups/main-x.tar.gz" "$T/good.tar.gz"; printf 'x' >> "$T/backups/main-x.tar.gz"
if compose_download "$T/down2" > /dev/null 2>&1; then echo "FAIL: sha256 mismatch not detected" >&2; exit 1; fi
cp "$T/good.tar.gz" "$T/backups/main-x.tar.gz"

# 3. copy-in: secrets stream into compose-init.sh restore-secrets (then its init mode runs against the fake config dir)
: > "$LOG"
compose_restore "$T/project" "$T/down/main-x.tar.gz" secrets 1 > "$T/restore.out" 2>&1 || { cat "$T/restore.out" >&2; echo "FAIL: compose_restore" >&2; exit 1; }
[ "$(cat "$T/config/secrets/cell-key/CELL_ENCRYPTION_KEY")" = "k3y" ] || { cat "$T/restore.out" >&2; echo "FAIL: secret not restored" >&2; exit 1; }
grep -q "restored secrets/cell-key" "$T/restore.out" || { cat "$T/restore.out" >&2; echo "FAIL: restore-secrets output missing" >&2; exit 1; }
grep -q -- '-v' "$LOG" && { echo "FAIL: bind mount in restore" >&2; exit 1; }
# 4. the health wait reads both `compose ps` JSON shapes and names what is wrong
cat > "$T/ps.json" <<'JSON'
{"Name":"matelot-api-1","Service":"api","State":"running","Health":"healthy","ExitCode":0}
{"Name":"matelot-init-1","Service":"init","State":"exited","Health":"","ExitCode":0}
{"Name":"matelot-keycloak-1","Service":"keycloak","State":"restarting","Health":"","ExitCode":1}
{"Name":"matelot-worker-1","Service":"worker","State":"running","Health":"starting","ExitCode":0}
JSON
export FAKE_PS="$T/ps.json"
[ "$(compose_unhealthy | sort | tr '\n' ' ')" = "matelot-keycloak-1 matelot-worker-1 " ] || { echo "FAIL: unhealthy detection: $(compose_unhealthy | tr '\n' ' ')" >&2; exit 1; }
printf '[{"Name":"a","State":"running","Health":""},{"Name":"b","State":"exited","ExitCode":2}]' > "$T/ps.json"
[ "$(compose_unhealthy | tr '\n' ' ')" = "b " ] || { echo "FAIL: array-shaped ps" >&2; exit 1; }
if compose_wait_healthy 0 > "$T/wait.out" 2>&1; then echo "FAIL: wait should fail" >&2; exit 1; fi
grep -q "not healthy after 0s: b" "$T/wait.out" || { cat "$T/wait.out" >&2; echo "FAIL: wait diagnostics" >&2; exit 1; }
printf '{"Name":"a","State":"running","Health":"healthy"}\n' > "$T/ps.json"
compose_wait_healthy 0 > /dev/null || { echo "FAIL: healthy stack reported unhealthy" >&2; exit 1; }

# 5. full restore: the registry blobs are counted against the archive (a short extraction is an error, "0 files" never silent)
mkdir -p "$T/src/main-x/docker/registry/v2/blobs"; printf 'blob' > "$T/src/main-x/docker/registry/v2/blobs/sha256-1"; printf 'blob' > "$T/src/main-x/docker/registry/v2/blobs/sha256-2"
tar -C "$T/src/main-x/docker" -cf "$T/src/main-x/registry.tar" .; rm -rf "$T/src/main-x/docker"
tar -C "$T/src" -czf "$T/full.tar.gz" main-x
: > "$LOG"; rm -rf "$T/registry"; mkdir -p "$T/registry"
compose_restore "$T/project" "$T/full.tar.gz" all 1 > "$T/full.out" 2>&1 || { cat "$T/full.out" >&2; echo "FAIL: full restore" >&2; exit 1; }
grep -q "restoring registry blobs (2 files in the archive)" "$T/full.out" && grep -q "^  2 files" "$T/full.out" || { cat "$T/full.out" >&2; echo "FAIL: registry count" >&2; exit 1; }
[ "$(find "$T/registry" -type f | wc -l)" = 2 ] || { echo "FAIL: blobs not extracted" >&2; exit 1; }
grep -q "restore done from full.tar.gz" "$T/full.out" || { cat "$T/full.out" >&2; echo "FAIL: restore did not finish" >&2; exit 1; }
grep -q -- 'ALIGN_SOCKET=/var/run/postgresql' "$LOG" || { echo "FAIL: restore-db.sh not told to align the role password" >&2; exit 1; }
grep -q -- 'stop api worker keycloak runner registry welcome' "$LOG" || { echo "FAIL: dependants not stopped before the restore" >&2; exit 1; }
# a short extraction (the volume ends up with fewer files than the archive) is an error, never "0 files" and success
rm -rf "$T/registry"; mkdir -p "$T/registry"
if FAKE_REGISTRY_TRUNCATE=1 compose_restore "$T/project" "$T/full.tar.gz" all 1 > "$T/short.out" 2>&1; then cat "$T/short.out" >&2; echo "FAIL: short registry restore reported success" >&2; exit 1; fi
grep -q "registry restore incomplete: 1 files in the volume, 2 in the archive" "$T/short.out" || { cat "$T/short.out" >&2; echo "FAIL: short-extraction message" >&2; exit 1; }

echo "compose-lib ok (copy-out streamed + verified, copy-in streamed into restore-secrets, health wait, registry count, no bind mounts, uid $(id -u))"
