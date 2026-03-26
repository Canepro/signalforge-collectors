#!/usr/bin/env bash
#
# Collect one container's runtime posture into the text format expected by
# SignalForge's container-diagnostics adapter.
#
set -euo pipefail

RUNTIME="${SIGNALFORGE_CONTAINER_RUNTIME:-auto}"
CONTAINER_REF="${SIGNALFORGE_CONTAINER_REF:-}"
HOST_LABEL="${SIGNALFORGE_CONTAINER_HOSTNAME:-}"
OUTPUT_PATH=""

show_help() {
  cat <<'EOF'
Collect a container-diagnostics artifact for one container.

Usage:
  ./collect-container-diagnostics.sh --container NAME_OR_ID [options]

Options:
  --container, -c REF  Required container name or id
  --runtime NAME       Runtime command: auto, podman, or docker (default: auto)
  --hostname NAME      Override host label written into the artifact
  --output, -o PATH    Write artifact to PATH instead of an auto-generated file
  -h, --help           Show this help

Environment:
  SIGNALFORGE_CONTAINER_RUNTIME   Default runtime when --runtime is omitted
  SIGNALFORGE_CONTAINER_REF       Default container reference when --container is omitted
  SIGNALFORGE_CONTAINER_HOSTNAME  Default host label when --hostname is omitted
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container|-c)
      CONTAINER_REF="${2:?missing value after $1}"
      shift 2
      ;;
    --runtime)
      RUNTIME="${2:?missing value after $1}"
      shift 2
      ;;
    --hostname)
      HOST_LABEL="${2:?missing value after $1}"
      shift 2
      ;;
    --output|-o)
      OUTPUT_PATH="${2:?missing value after $1}"
      shift 2
      ;;
    --help|-h)
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

if [[ -z "$CONTAINER_REF" ]]; then
  echo "error: --container is required" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to parse runtime inspect output" >&2
  exit 1
fi

resolve_runtime() {
  if [[ "$RUNTIME" != "auto" ]]; then
    if ! command -v "$RUNTIME" >/dev/null 2>&1; then
      echo "error: runtime command not found: $RUNTIME" >&2
      exit 1
    fi
    printf '%s\n' "$RUNTIME"
    return
  fi

  local candidate=""
  for candidate in podman docker; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  echo "error: no supported container runtime found (tried: podman, docker)" >&2
  exit 1
}

sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'
}

if [[ -z "$HOST_LABEL" ]]; then
  HOST_LABEL="$(hostname -s 2>/dev/null || hostname)"
fi

RUNTIME_CMD="$(resolve_runtime)"
if [[ -z "$OUTPUT_PATH" ]]; then
  TS="$(date -u '+%Y%m%d_%H%M%S')"
  OUTPUT_PATH="./container_diagnostics_$(sanitize_name "$CONTAINER_REF")_${TS}.txt"
fi

INSPECT_JSON="$("$RUNTIME_CMD" inspect "$CONTAINER_REF")"

INSPECT_JSON="$INSPECT_JSON" python3 - "$RUNTIME_CMD" "$HOST_LABEL" "$OUTPUT_PATH" <<'PY'
import json
import os
import sys

runtime = sys.argv[1]
hostname = sys.argv[2]
output_path = sys.argv[3]
raw = os.environ.get("INSPECT_JSON", "")
parsed = json.loads(raw)
item = parsed[0] if isinstance(parsed, list) and parsed else parsed
if not isinstance(item, dict):
    raise SystemExit("runtime inspect did not return a container object")

host_config = item.get("HostConfig") or {}
config = item.get("Config") or {}
network_settings = item.get("NetworkSettings") or {}
mounts = item.get("Mounts") or []


def as_bool(value):
    return "true" if bool(value) else "false"


def as_list(value):
    if not value:
        return []
    if isinstance(value, list):
        return [str(entry).strip() for entry in value if str(entry).strip()]
    return [str(value).strip()]


def is_root(user_value):
    user = str(user_value or "").strip()
    return user in ("", "0", "root") or user.startswith("0:") or user.startswith("root:")


def first_truthy(*values):
    for value in values:
        if value:
            return value
    return ""


def format_mount(entry):
    mount_type = str(entry.get("Type") or "").strip().lower()
    source = str(entry.get("Source") or "").strip()
    destination = str(entry.get("Destination") or "").strip()
    name = str(entry.get("Name") or "").strip()

    if mount_type == "bind" and source and destination:
        return f"{source}:{destination}"
    if mount_type == "volume" and destination:
        volume_name = name or source or "volume"
        return f"{volume_name}:{destination}" if volume_name and volume_name != destination else f"volume:{destination}"
    if mount_type == "tmpfs" and destination:
        return f"tmpfs:{destination}"
    if source and destination:
        return f"{source}:{destination}"
    if destination:
        return f"{mount_type or 'mount'}:{destination}"
    return ""


published_ports = []
for container_port, bindings in (network_settings.get("Ports") or {}).items():
    if not bindings:
        continue
    for binding in bindings:
        host_port = str((binding or {}).get("HostPort") or "").strip()
        if not host_port:
            continue
        published_ports.append(f"{host_port}:{container_port}")

mount_entries = [formatted for formatted in (format_mount(entry) for entry in mounts) if formatted]
writable_mounts = []
secret_mounts = []
for entry in mounts:
    destination = str(entry.get("Destination") or "").strip()
    if destination and entry.get("RW") is True:
        writable_mounts.append(destination)
    source = str(entry.get("Source") or "").lower()
    target = destination.lower()
    if "/run/secrets" in target or "secret" in source or "secret" in target:
        if destination:
            secret_mounts.append(destination)

security_options = [str(value).lower() for value in as_list(host_config.get("SecurityOpt"))]
allow_privilege_escalation = not any("no-new-privileges" in value for value in security_options)

name = str(item.get("Name") or "").lstrip("/")
container_id = str(item.get("Id") or "").strip()
container_id = container_id[:12] if len(container_id) > 12 else container_id

lines = [
    "=== container-diagnostics ===",
    f"hostname: {hostname}",
    f"runtime: {runtime}",
    f"container_name: {first_truthy(name, str(item.get('Names') or '').lstrip('/'), 'unknown-container')}",
    f"container_id: {first_truthy(container_id, 'unknown-container-id')}",
    f"image: {first_truthy(str(config.get('Image') or '').strip(), str(item.get('ImageName') or '').strip(), 'unknown-image')}",
    f"published_ports: {', '.join(published_ports) if published_ports else 'none'}",
    f"privileged: {as_bool(host_config.get('Privileged'))}",
    f"host_network: {as_bool(str(host_config.get('NetworkMode') or '').strip() == 'host')}",
    f"host_pid: {as_bool(str(host_config.get('PidMode') or '').strip() == 'host')}",
    f"added_capabilities: {', '.join(as_list(host_config.get('CapAdd'))) if as_list(host_config.get('CapAdd')) else 'none'}",
    f"allow_privilege_escalation: {as_bool(allow_privilege_escalation)}",
    f"mounts: {', '.join(mount_entries) if mount_entries else 'none'}",
    f"writable_mounts: {', '.join(writable_mounts) if writable_mounts else 'none'}",
    f"read_only_rootfs: {as_bool(host_config.get('ReadonlyRootfs'))}",
    f"secrets: {', '.join(secret_mounts) if secret_mounts else 'none'}",
    f"ran_as_root: {as_bool(is_root(config.get('User')))}",
]

with open(output_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY

echo "Wrote $OUTPUT_PATH"
