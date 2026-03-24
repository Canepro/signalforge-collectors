#!/usr/bin/env bash
#
# Reference push collector: run first-audit.sh (or use an existing audit log), then POST
# the artifact to SignalForge with ingestion metadata (external submit contract).
#
# SignalForge analyzes evidence only; it does not run this script or collect on hosts.
# This pattern is intentionally narrow (Linux host audit today). The same POST /api/runs
# contract can later be used by:
#   - Kubernetes / container diagnostics bundles
#   - Windows / macOS evidence packs
#   - other collectors — swap the artifact generator; keep the multipart metadata shape.
#
# Contract: SignalForge docs/external-submit.md (multipart POST /api/runs).
#
set -euo pipefail

SCRIPT_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SAK_COLLECTOR_TYPE="signalforge-collectors"
readonly SAK_SOURCE_LABEL="signalforge-collectors:first-audit.sh"
# Bump when this submit wrapper or advertised behavior changes (not the whole toolkit).
readonly SAK_REFERENCE_VERSION="1.0.0"

BASE_URL="${SIGNALFORGE_URL:-http://localhost:3000}"
TARGET_ID=""
ARTIFACT=""
RUN_AUDIT=1

show_help() {
  cat <<'EOF'
Reference collector: capture a host audit (first-audit.sh) and push to SignalForge.

Usage:
  ./submit-to-signalforge.sh [options]
  ./submit-to-signalforge.sh [options] --file PATH/to/server_audit_*.log

Options:
  --url, -u BASE     SignalForge base URL (default: SIGNALFORGE_URL or http://localhost:3000)
  --target-id ID     Optional stable target key (default: short hostname)
  --file, -f PATH    Submit an existing audit log; skip running first-audit.sh
  -h, --help         Show this help

Environment:
  SIGNALFORGE_URL    Default base URL if --url is not passed

Without --file, runs ./first-audit.sh in this repo directory, then uploads the newest
server_audit_*.log written by that run.

Metadata sent (multipart form fields): target_identifier, source_label, collector_type,
collector_version, collected_at, source_type=api — see SignalForge docs/external-submit.md.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --url|-u)
      BASE_URL="${2:?missing value after $1}"
      shift 2
      ;;
    --target-id)
      TARGET_ID="${2:?missing value after $1}"
      shift 2
      ;;
    --file|-f)
      ARTIFACT="${2:?missing value after $1}"
      RUN_AUDIT=0
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "error: unexpected argument: $1" >&2
      echo "Try: $0 --help" >&2
      exit 1
      ;;
  esac
done

cd "$SCRIPT_DIR"

if [[ "$RUN_AUDIT" -eq 1 ]]; then
  if [[ ! -x ./first-audit.sh ]]; then
    echo "error: ./first-audit.sh not found or not executable in $SCRIPT_DIR" >&2
    exit 1
  fi
  echo "→ Running first-audit.sh (capture evidence)..."
  ./first-audit.sh
  # shellcheck disable=SC2012
  ARTIFACT="$(ls -t server_audit_*.log 2>/dev/null | head -1 || true)"
  if [[ -z "$ARTIFACT" ]]; then
    echo "error: no server_audit_*.log produced after first-audit.sh" >&2
    exit 1
  fi
else
  if [[ -z "$ARTIFACT" ]]; then
    echo "error: --file requires a path" >&2
    exit 1
  fi
  if [[ ! -f "$ARTIFACT" ]]; then
    echo "error: not a file: $ARTIFACT" >&2
    exit 1
  fi
fi

if [[ -z "$TARGET_ID" ]]; then
  TARGET_ID="$(hostname -s 2>/dev/null || hostname)"
fi

COLLECTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo "→ Submitting to SignalForge: $BASE_URL"
echo "  artifact:        $ARTIFACT"
echo "  target_identifier: $TARGET_ID"
echo "  source_label:    $SAK_SOURCE_LABEL"
echo "  collector_type:  $SAK_COLLECTOR_TYPE"
echo "  collector_version: $SAK_REFERENCE_VERSION"
echo "  collected_at:    $COLLECTED_AT"

CURL_ARGS=(-sS -X POST)
CURL_ARGS+=(-F "file=@${ARTIFACT}")
CURL_ARGS+=(-F "source_type=api")
CURL_ARGS+=(-F "target_identifier=${TARGET_ID}")
CURL_ARGS+=(-F "source_label=${SAK_SOURCE_LABEL}")
CURL_ARGS+=(-F "collector_type=${SAK_COLLECTOR_TYPE}")
CURL_ARGS+=(-F "collector_version=${SAK_REFERENCE_VERSION}")
CURL_ARGS+=(-F "collected_at=${COLLECTED_AT}")

RESP="$(curl "${CURL_ARGS[@]}" "${BASE_URL%/}/api/runs")"

if command -v jq >/dev/null 2>&1; then
  RUN_ID="$(echo "$RESP" | jq -r '.run_id // empty')"
  ERR="$(echo "$RESP" | jq -r '.error // empty')"
else
  RUN_ID="$(printf '%s' "$RESP" | sed -n 's/.*"run_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  ERR=""
fi

if [[ -n "${ERR:-}" ]]; then
  echo "error: submission failed: $ERR" >&2
  printf '%s\n' "$RESP" >&2
  exit 1
fi

if [[ -z "${RUN_ID:-}" ]]; then
  echo "error: could not parse run_id from response:" >&2
  printf '%s\n' "$RESP" >&2
  exit 1
fi

echo ""
echo "✓ Submission succeeded"
echo "  run_id: $RUN_ID"
echo "  url:    ${BASE_URL%/}/runs/${RUN_ID}"
