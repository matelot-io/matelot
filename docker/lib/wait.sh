# shellcheck shell=bash
# Progress-printing waits for the cell scripts. Source it; needs python3 and kubectl.
#   wait_cell <namespace> <release> <timeout-seconds>     until every Deployment / StatefulSet of the release is rolled out
#                                                         (kubectl rollout status semantics: generation observed, all replicas updated AND ready, no old one left)
#   wait_job  <namespace> <job> <timeout-seconds>         until the Job completes (fails when the Job fails)
#   wait_pvs  <timeout-seconds> <pv> [<pv> …]             until the PersistentVolumes are gone
# A line every WAIT_INTERVAL seconds (default 15) says what is still not ready; anything that will not fix itself
# (ImagePullBackOff, CrashLoopBackOff, Pending for minutes, a failed Job) is flagged the moment it appears; on timeout
# a summary names what never became ready and the commands to look at it.
CELLWAIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cellwait.py"
WAIT_INTERVAL="${WAIT_INTERVAL:-15}"

_wait_loop() { # _wait_loop <timeout> <describe-hint> <mode> <args…>
  local timeout="$1" hint="$2"; shift 2
  local start now elapsed snap seen="" line
  start="$(date +%s)"
  while :; do
    snap="$(python3 "$CELLWAIT" "$@")" || { echo "   (status check failed)" >&2; snap='{"done":false,"failed":false,"summary":"status unavailable","waiting":[],"stuck":[],"info":[]}'; }
    now="$(date +%s)"; elapsed=$((now - start))
    local stamp; stamp="$(printf '[%02d:%02d]' $((elapsed / 60)) $((elapsed % 60)))"
    # one line per tick, plus a warning the first time something looks stuck
    line="$(printf '%s' "$snap" | python3 -c '
import json, sys
s = json.load(sys.stdin)
parts = [s["summary"]]
if s["waiting"]: parts.append("waiting: " + ", ".join(s["waiting"]))
if s["info"]: parts.append("not blocking: " + ", ".join(s["info"]))
print(" · ".join(parts))
for x in s["stuck"]: print("STUCK\t" + x["key"] + "\t" + x["text"])
print("DONE" if s["done"] else "WAIT", "FAILED" if s["failed"] else "OK")
')"
    local verdict; verdict="$(printf '%s\n' "$line" | tail -1)"
    printf '%s\n' "$line" | sed '$d' | while IFS= read -r l; do
      case "$l" in
        STUCK*) ;;
        *) echo "   $stamp $l";;
      esac
    done
    while IFS= read -r l; do
      case "$l" in STUCK*) l="${l#STUCK	}"; key="${l%%	*}"; l="${l#*	}"; case "$seen" in *"<$key>"*) ;; *) seen="$seen<$key>"; echo "   $stamp WARNING: $l" >&2;; esac;; esac
    done <<< "$line"
    case "$verdict" in
      "DONE OK") return 0;;
      "DONE FAILED") echo "   $stamp failed. Look at: $hint" >&2; return 1;;
    esac
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "   $stamp timed out after ${timeout}s; never ready:" >&2
      printf '%s' "$snap" | python3 -c 'import json,sys; s=json.load(sys.stdin); items = s["waiting"] + [x["text"] for x in s["stuck"]] or [s["summary"] + " (nothing listed as waiting: the last status check may have failed)"]; [print("      " + w) for w in items]' >&2
      echo "   look at: $hint" >&2
      return 1
    fi
    sleep "$WAIT_INTERVAL"
  done
}

wait_cell() { # <namespace> <release> <timeout>
  local ns="$1" rel="$2" timeout="$3"
  _wait_loop "$timeout" "kubectl -n $ns get pods; kubectl -n $ns describe pod <name>; kubectl -n $ns logs <name> --all-containers" cell "$ns" "$rel"
}
wait_job() { # <namespace> <job> <timeout>
  local ns="$1" job="$2" timeout="$3"
  _wait_loop "$timeout" "kubectl -n $ns logs job/$job --all-containers; kubectl -n $ns describe job $job" job "$ns" "$job"
}
wait_pvs() { # <timeout> <pv>…
  local timeout="$1"; shift
  [ $# -gt 0 ] || return 0
  _wait_loop "$timeout" "kubectl get pv; kubectl describe pv <name> (a Retain reclaim policy keeps the volume on purpose)" pvs "$@"
}
