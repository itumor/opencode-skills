#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<USAGE
Usage: $0 --run-dir <dir> --writer <live|dr|ga|host> [--pause-sec N]
USAGE
}

RUN_DIR=""
WRITER=""
PAUSE_SEC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --writer) WRITER="$2"; shift 2 ;;
    --pause-sec) PAUSE_SEC="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_DIR" ]] || { usage; die "--run-dir is required"; }
[[ -n "$WRITER" ]] || { usage; die "--writer is required"; }

load_env_defaults
ensure_run_dirs "$RUN_DIR"

writer_host="$(resolve_writer_host "$WRITER")"
[[ -n "$writer_host" ]] || die "resolved writer host is empty for: $WRITER"

echo "$WRITER" >"${RUN_DIR}/state/active_writer"
echo "$writer_host" >"${RUN_DIR}/state/active_writer_host"
log "active writer switched to label=${WRITER} host=${writer_host}"

if [[ "$PAUSE_SEC" -gt 0 ]]; then
  log "pausing writes for ${PAUSE_SEC}s to settle replication"
  sleep "$PAUSE_SEC"
fi
