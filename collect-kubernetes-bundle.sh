#!/usr/bin/env bash
#
# Collect a normalized Kubernetes evidence bundle in the JSON manifest format
# expected by SignalForge's kubernetes-bundle adapter.
#
set -euo pipefail

KUBECTL_BIN="${SIGNALFORGE_KUBECTL_BIN:-kubectl}"
KUBECTL_CONTEXT="${SIGNALFORGE_KUBERNETES_CONTEXT:-}"
SCOPE="${SIGNALFORGE_KUBERNETES_SCOPE:-cluster}"
NAMESPACE="${SIGNALFORGE_KUBERNETES_NAMESPACE:-}"
CLUSTER_NAME="${SIGNALFORGE_KUBERNETES_CLUSTER_NAME:-}"
PROVIDER="${SIGNALFORGE_KUBERNETES_PROVIDER:-}"
OUTPUT_PATH=""
COLLECTOR_VERSION="${SIGNALFORGE_COLLECTOR_VERSION:-1.1.0}"

show_help() {
  cat <<'EOF'
Collect a kubernetes-bundle.v1 artifact from an explicit or current kubectl context.

Usage:
  ./collect-kubernetes-bundle.sh [options]

Options:
  --scope LEVEL         cluster or namespace (default: cluster)
  --namespace NAME      Namespace to scope collection to; implies --scope namespace
  --context NAME        Explicit kubectl context to use
  --cluster-name NAME   Override cluster name in the manifest
  --provider NAME       Optional provider label (aks, eks, gke, oke, ...)
  --kubectl PATH        kubectl command to use (default: kubectl)
  --output, -o PATH     Write artifact to PATH instead of an auto-generated file
  -h, --help            Show this help

Environment:
  SIGNALFORGE_KUBECTL_BIN
  SIGNALFORGE_KUBERNETES_CONTEXT
  SIGNALFORGE_KUBERNETES_SCOPE
  SIGNALFORGE_KUBERNETES_NAMESPACE
  SIGNALFORGE_KUBERNETES_CLUSTER_NAME
  SIGNALFORGE_KUBERNETES_PROVIDER
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPE="${2:?missing value after $1}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:?missing value after $1}"
      SCOPE="namespace"
      shift 2
      ;;
    --context)
      KUBECTL_CONTEXT="${2:?missing value after $1}"
      shift 2
      ;;
    --cluster-name)
      CLUSTER_NAME="${2:?missing value after $1}"
      shift 2
      ;;
    --provider)
      PROVIDER="${2:?missing value after $1}"
      shift 2
      ;;
    --kubectl)
      KUBECTL_BIN="${2:?missing value after $1}"
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

if [[ "$SCOPE" != "cluster" && "$SCOPE" != "namespace" ]]; then
  echo "error: --scope must be cluster or namespace" >&2
  exit 1
fi

if [[ "$SCOPE" == "namespace" && -z "$NAMESPACE" ]]; then
  echo "error: --namespace is required when --scope namespace is used" >&2
  exit 1
fi

if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
  echo "error: kubectl command not found: $KUBECTL_BIN" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to assemble the Kubernetes bundle" >&2
  exit 1
fi

sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_empty_json() {
  printf '%s\n' '{"items":[]}' > "$1"
}

write_empty_text() {
  : > "$1"
}

kubectl_args=()
if [[ -n "$KUBECTL_CONTEXT" ]]; then
  kubectl_args+=(--context "$KUBECTL_CONTEXT")
fi

capture_json() {
  local outfile="$1"
  local required="$2"
  shift 2

  if "$KUBECTL_BIN" "${kubectl_args[@]}" "$@" -o json >"$outfile" 2>"$TMP_DIR/command.err"; then
    return 0
  fi

  if [[ "$required" == "required" ]]; then
    echo "error: kubectl ${kubectl_args[*]} $* failed" >&2
    cat "$TMP_DIR/command.err" >&2
    exit 1
  fi

  echo "warning: kubectl ${kubectl_args[*]} $* failed; continuing with empty result" >&2
  cat "$TMP_DIR/command.err" >&2
  write_empty_json "$outfile"
}

capture_text() {
  local outfile="$1"
  local required="$2"
  shift 2

  if "$KUBECTL_BIN" "${kubectl_args[@]}" "$@" >"$outfile" 2>"$TMP_DIR/command.err"; then
    return 0
  fi

  if [[ "$required" == "required" ]]; then
    echo "error: kubectl ${kubectl_args[*]} $* failed" >&2
    cat "$TMP_DIR/command.err" >&2
    exit 1
  fi

  echo "warning: kubectl ${kubectl_args[*]} $* failed; continuing with empty result" >&2
  cat "$TMP_DIR/command.err" >&2
  write_empty_text "$outfile"
}

capture_json "$TMP_DIR/config.json" required config view

scope_args=()
if [[ "$SCOPE" == "namespace" ]]; then
  scope_args=(-n "$NAMESPACE")
else
  scope_args=(-A)
fi

capture_json "$TMP_DIR/services.json" optional get services "${scope_args[@]}"
capture_json "$TMP_DIR/networkpolicies.json" optional get networkpolicies "${scope_args[@]}"
capture_json "$TMP_DIR/rolebindings.json" optional get rolebindings "${scope_args[@]}"
capture_json "$TMP_DIR/roles.json" optional get roles "${scope_args[@]}"
capture_json "$TMP_DIR/deployments.json" optional get deployments "${scope_args[@]}"
capture_json "$TMP_DIR/statefulsets.json" optional get statefulsets "${scope_args[@]}"
capture_json "$TMP_DIR/daemonsets.json" optional get daemonsets "${scope_args[@]}"
capture_json "$TMP_DIR/jobs.json" optional get jobs "${scope_args[@]}"
capture_json "$TMP_DIR/cronjobs.json" optional get cronjobs "${scope_args[@]}"
capture_json "$TMP_DIR/pods.json" optional get pods "${scope_args[@]}"
capture_json "$TMP_DIR/replicasets.json" optional get replicasets "${scope_args[@]}"
capture_json "$TMP_DIR/events.json" optional get events "${scope_args[@]}"
capture_json "$TMP_DIR/nodes.json" optional get nodes
capture_json "$TMP_DIR/clusterroles.json" optional get clusterroles
capture_json "$TMP_DIR/clusterrolebindings.json" optional get clusterrolebindings
capture_json "$TMP_DIR/hpas.json" optional get horizontalpodautoscalers "${scope_args[@]}"
capture_json "$TMP_DIR/poddisruptionbudgets.json" optional get poddisruptionbudgets "${scope_args[@]}"
capture_json "$TMP_DIR/resourcequotas.json" optional get resourcequotas "${scope_args[@]}"
capture_json "$TMP_DIR/limitranges.json" optional get limitranges "${scope_args[@]}"
capture_json "$TMP_DIR/persistentvolumeclaims.json" optional get persistentvolumeclaims "${scope_args[@]}"
capture_json "$TMP_DIR/persistentvolumes.json" optional get persistentvolumes
capture_text "$TMP_DIR/top-pods.txt" optional top pods "${scope_args[@]}" --no-headers
capture_text "$TMP_DIR/top-nodes.txt" optional top nodes --no-headers

if [[ -z "$OUTPUT_PATH" ]]; then
  TS="$(date -u '+%Y%m%d_%H%M%S')"
  if [[ "$SCOPE" == "namespace" ]]; then
    BASE_NAME="kubernetes_bundle_$(sanitize_name "$NAMESPACE")_${TS}.json"
  else
    BASE_NAME="kubernetes_bundle_cluster_${TS}.json"
  fi
  OUTPUT_PATH="./${BASE_NAME}"
fi

python3 - "$TMP_DIR" "$SCOPE" "$NAMESPACE" "$CLUSTER_NAME" "$PROVIDER" "$OUTPUT_PATH" "$COLLECTOR_VERSION" "$KUBECTL_CONTEXT" "$KUBECTL_BIN" <<'PY'
import json
import os
import subprocess
import sys
import re
from datetime import datetime, timezone

tmp_dir, scope_level, namespace, cluster_name_arg, provider_arg, output_path, collector_version, explicit_context, kubectl_bin = sys.argv[1:]


def load(name):
    path = os.path.join(tmp_dir, name)
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def load_text(name):
    path = os.path.join(tmp_dir, name)
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def items(doc):
    value = doc.get("items")
    return value if isinstance(value, list) else []


def first_owner(metadata):
    owners = metadata.get("ownerReferences") or []
    return owners[0] if owners else None


def as_text(value):
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def log_priority(reason, restarts):
    if reason == "CrashLoopBackOff":
        return 100
    if reason == "OOMKilled":
        return 90
    if reason in {"ContainerCannotRun", "RunContainerError", "CreateContainerError", "CreateContainerConfigError", "StartError"}:
        return 80
    if reason == "Error":
        return 70
    if restarts >= 3:
        return 60
    if restarts > 0:
        return 40
    return 0


def parse_quantity(value):
    text = as_text(value)
    if text is None:
        return None

    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([A-Za-z]+)?", text)
    if not match:
        return None

    number = float(match.group(1))
    suffix = match.group(2) or ""
    factors = {
        "": 1.0,
        "n": 0.000000001,
        "u": 0.000001,
        "m": 0.001,
        "Ki": 1024.0,
        "Mi": 1024.0**2,
        "Gi": 1024.0**3,
        "Ti": 1024.0**4,
        "Pi": 1024.0**5,
        "Ei": 1024.0**6,
        "K": 1000.0,
        "M": 1000.0**2,
        "G": 1000.0**3,
        "T": 1000.0**4,
        "P": 1000.0**5,
        "E": 1000.0**6,
    }
    factor = factors.get(suffix)
    if factor is None:
        return None
    return number * factor


def ratio_value(used, hard):
    used_value = parse_quantity(used)
    hard_value = parse_quantity(hard)
    if used_value is None or hard_value in (None, 0):
        return None
    return used_value / hard_value


def infer_provider(cluster_name):
    lowered = (cluster_name or "").lower()
    for token in ("aks", "eks", "gke", "oke", "k3s", "kind", "minikube"):
        if token in lowered:
            return token
    return None


config = load("config.json")
services_doc = load("services.json")
network_policies_doc = load("networkpolicies.json")
role_bindings_doc = load("rolebindings.json")
roles_doc = load("roles.json")
horizontal_pod_autoscalers_doc = load("hpas.json")
pod_disruption_budgets_doc = load("poddisruptionbudgets.json")
resource_quotas_doc = load("resourcequotas.json")
limit_ranges_doc = load("limitranges.json")
persistent_volume_claims_doc = load("persistentvolumeclaims.json")
persistent_volumes_doc = load("persistentvolumes.json")
deployments_doc = load("deployments.json")
statefulsets_doc = load("statefulsets.json")
daemonsets_doc = load("daemonsets.json")
jobs_doc = load("jobs.json")
cronjobs_doc = load("cronjobs.json")
pods_doc = load("pods.json")
replicasets_doc = load("replicasets.json")
events_doc = load("events.json")
nodes_doc = load("nodes.json")
clusterroles_doc = load("clusterroles.json")
clusterrolebindings_doc = load("clusterrolebindings.json")
top_pods_raw = load_text("top-pods.txt")
top_nodes_raw = load_text("top-nodes.txt")

current_context_name = explicit_context or config.get("current-context")
contexts = {
    ctx.get("name"): (ctx.get("context") or {})
    for ctx in config.get("contexts", [])
    if isinstance(ctx, dict)
}
context = contexts.get(current_context_name, {})
resolved_cluster_name = cluster_name_arg or context.get("cluster") or "unknown-cluster"
provider = provider_arg or infer_provider(resolved_cluster_name)

service_exposure = []
for service in items(services_doc):
    metadata = service.get("metadata") or {}
    spec = service.get("spec") or {}
    status = service.get("status") or {}
    service_type = spec.get("type") or "ClusterIP"
    external = service_type in {"LoadBalancer", "NodePort"} or bool((status.get("loadBalancer") or {}).get("ingress"))
    service_exposure.append(
        {
            "namespace": metadata.get("namespace"),
            "name": metadata.get("name"),
            "type": service_type,
            "external": external,
        }
    )

network_policies = []
for policy in items(network_policies_doc):
    metadata = policy.get("metadata") or {}
    network_policies.append(
        {
            "namespace": metadata.get("namespace"),
            "name": metadata.get("name"),
        }
    )


def hpa_current_cpu_utilization(hpa_status):
    current_cpu = hpa_status.get("currentCPUUtilizationPercentage")
    if current_cpu is not None:
        return as_int(current_cpu)

    for metric in hpa_status.get("currentMetrics") or []:
        resource = (metric or {}).get("resource") or {}
        if str(resource.get("name") or "").strip().lower() != "cpu":
            continue
        current = resource.get("current") or {}
        utilization = current.get("averageUtilization")
        if utilization is not None:
            return as_int(utilization)
    return None


def hpa_target_cpu_utilization(hpa_spec):
    target_cpu = hpa_spec.get("targetCPUUtilizationPercentage")
    if target_cpu is not None:
        return as_int(target_cpu)

    for metric in hpa_spec.get("metrics") or []:
        resource = (metric or {}).get("resource") or {}
        if str(resource.get("name") or "").strip().lower() != "cpu":
            continue
        target = resource.get("target") or {}
        if str(target.get("type") or "").strip().lower() != "utilization":
            continue
        utilization = target.get("averageUtilization")
        if utilization is not None:
            return as_int(utilization)
    return None


hpa_state = []
for hpa in items(horizontal_pod_autoscalers_doc):
    metadata = hpa.get("metadata") or {}
    spec = hpa.get("spec") or {}
    status = hpa.get("status") or {}
    scale_target_ref = spec.get("scaleTargetRef") or {}
    hpa_state.append(
        {
            "namespace": metadata.get("namespace"),
            "name": metadata.get("name"),
            "scale_target_kind": scale_target_ref.get("kind"),
            "scale_target_name": scale_target_ref.get("name"),
            "min_replicas": as_int(spec.get("minReplicas")),
            "max_replicas": as_int(spec.get("maxReplicas")),
            "current_replicas": as_int(status.get("currentReplicas")),
            "desired_replicas": as_int(status.get("desiredReplicas")),
            "current_cpu_utilization_percentage": hpa_current_cpu_utilization(status),
            "target_cpu_utilization_percentage": hpa_target_cpu_utilization(spec),
            "conditions": [
                {
                    "type": condition.get("type"),
                    "status": condition.get("status"),
                    "reason": condition.get("reason"),
                    "message": condition.get("message"),
                }
                for condition in status.get("conditions") or []
            ],
        }
    )


pdb_state = []
for pdb in items(pod_disruption_budgets_doc):
    metadata = pdb.get("metadata") or {}
    spec = pdb.get("spec") or {}
    status = pdb.get("status") or {}
    min_available = spec.get("minAvailable")
    max_unavailable = spec.get("maxUnavailable")
    pdb_state.append(
        {
            "namespace": metadata.get("namespace"),
            "name": metadata.get("name"),
            "min_available": as_text(min_available),
            "max_unavailable": as_text(max_unavailable),
            "current_healthy": as_int(status.get("currentHealthy")),
            "desired_healthy": as_int(status.get("desiredHealthy")),
            "disruptions_allowed": as_int(status.get("disruptionsAllowed")),
            "expected_pods": as_int(status.get("expectedPods")),
        }
    )


resource_quota_state = []
for resource_quota in items(resource_quotas_doc):
    metadata = resource_quota.get("metadata") or {}
    status = resource_quota.get("status") or {}
    hard = status.get("hard") or {}
    used = status.get("used") or {}
    resources = []
    for resource_name in sorted(set(hard) | set(used)):
        hard_value = as_text(hard.get(resource_name))
        used_value = as_text(used.get(resource_name))
        resources.append(
            {
                "resource": resource_name,
                "hard": hard_value,
                "used": used_value,
                "used_ratio": ratio_value(used_value, hard_value),
            }
        )

    resource_quota_state.append(
        {
            "namespace": metadata.get("namespace"),
            "name": metadata.get("name"),
            "resources": resources,
        }
    )


limit_range_state = []
for limit_range in items(limit_ranges_doc):
    metadata = limit_range.get("metadata") or {}
    spec = limit_range.get("spec") or {}
    has_default_requests = False
    has_default_limits = False
    for limit in spec.get("limits") or []:
        if not has_default_requests and (limit.get("defaultRequest") or {}):
            has_default_requests = True
        if not has_default_limits and (limit.get("default") or {}):
            has_default_limits = True
        if has_default_requests and has_default_limits:
            break

    limit_range_state.append(
        {
            "namespace": metadata.get("namespace"),
            "name": metadata.get("name"),
            "has_default_requests": has_default_requests,
            "has_default_limits": has_default_limits,
        }
    )


persistent_volume_claim_state = []
for claim in items(persistent_volume_claims_doc):
    metadata = claim.get("metadata") or {}
    spec = claim.get("spec") or {}
    status = claim.get("status") or {}
    conditions = []
    for condition in status.get("conditions") or []:
        conditions.append(
            {
                "type": condition.get("type"),
                "status": condition.get("status"),
                "reason": condition.get("reason"),
                "message": condition.get("message"),
            }
        )

    persistent_volume_claim_state.append(
        {
            "namespace": metadata.get("namespace"),
            "name": metadata.get("name"),
            "phase": status.get("phase"),
            "bound": str(status.get("phase") or "").strip().lower() == "bound",
            "storage_class_name": spec.get("storageClassName"),
            "volume_name": spec.get("volumeName"),
            "access_modes": spec.get("accessModes") or [],
            "volume_mode": spec.get("volumeMode"),
            "requested_storage": ((spec.get("resources") or {}).get("requests") or {}).get("storage"),
            "capacity_storage": (status.get("capacity") or {}).get("storage"),
            "conditions": conditions,
        }
    )


persistent_volume_state = []
for volume in items(persistent_volumes_doc):
    metadata = volume.get("metadata") or {}
    spec = volume.get("spec") or {}
    status = volume.get("status") or {}
    claim_ref = spec.get("claimRef") or {}
    persistent_volume_state.append(
        {
            "name": metadata.get("name"),
            "phase": status.get("phase"),
            "storage_class_name": spec.get("storageClassName"),
            "claim_namespace": claim_ref.get("namespace"),
            "claim_name": claim_ref.get("name"),
            "access_modes": spec.get("accessModes") or [],
            "volume_mode": spec.get("volumeMode"),
            "capacity_storage": (status.get("capacity") or {}).get("storage") or (spec.get("capacity") or {}).get("storage"),
            "reclaim_policy": spec.get("persistentVolumeReclaimPolicy"),
            "csi_driver": ((spec.get("csi") or {}).get("driver")),
        }
    )


def condition_status(conditions, condition_type):
    for condition in conditions or []:
        if condition.get("type") != condition_type:
            continue
        status = str(condition.get("status") or "").strip().lower()
        if status == "true":
            return True
        if status == "false":
            return False
    return None


node_health = []
for node in items(nodes_doc):
    metadata = node.get("metadata") or {}
    spec = node.get("spec") or {}
    status = node.get("status") or {}
    conditions = status.get("conditions") or []
    pressure_conditions = []
    for condition_name in ("MemoryPressure", "DiskPressure", "PIDPressure"):
        if condition_status(conditions, condition_name) is True:
            pressure_conditions.append(condition_name)

    node_health.append(
        {
            "name": metadata.get("name"),
            "ready": condition_status(conditions, "Ready"),
            "unschedulable": bool(spec.get("unschedulable")),
            "pressure_conditions": pressure_conditions,
        }
    )


warning_events = []
for event in items(events_doc):
    if str(event.get("type") or "").strip().lower() != "warning":
        continue
    metadata = event.get("metadata") or {}
    involved = event.get("regarding") or event.get("involvedObject") or {}
    series = event.get("series") or {}
    warning_events.append(
        {
            "namespace": metadata.get("namespace") or involved.get("namespace"),
            "involved_kind": involved.get("kind"),
            "involved_name": involved.get("name"),
            "reason": event.get("reason"),
            "message": event.get("message"),
            "count": event.get("count") or series.get("count") or 1,
            "last_timestamp": event.get("eventTime")
            or series.get("lastObservedTime")
            or event.get("lastTimestamp")
            or metadata.get("creationTimestamp"),
        }
    )


def parse_pod_top(raw, scope):
    rows = []
    for line in raw.splitlines():
        parts = line.split()
        if scope == "namespace":
            if len(parts) < 3:
                continue
            name, cpu, memory = parts[0], parts[1], parts[2]
            rows.append(
                {
                    "namespace": namespace or None,
                    "name": name,
                    "cpu": cpu,
                    "memory": memory,
                }
            )
            continue
        if len(parts) < 4:
            continue
        row_namespace, name, cpu, memory = parts[0], parts[1], parts[2], parts[3]
        rows.append(
            {
                "namespace": row_namespace,
                "name": name,
                "cpu": cpu,
                "memory": memory,
            }
        )
    return rows


def parse_percent(value):
    text = str(value or "").strip()
    if not text or not text.endswith("%"):
        return None
    try:
        return float(text[:-1])
    except ValueError:
        return None


def parse_node_top(raw):
    rows = []
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        name, cpu, cpu_percent, memory, memory_percent = parts[0], parts[1], parts[2], parts[3], parts[4]
        rows.append(
            {
                "name": name,
                "cpu": cpu,
                "cpu_percent": parse_percent(cpu_percent),
                "memory": memory,
                "memory_percent": parse_percent(memory_percent),
            }
        )
    return rows


pod_top = parse_pod_top(top_pods_raw, scope_level)
node_top = parse_node_top(top_nodes_raw)


def subject_string(subject, binding_namespace):
    kind = str(subject.get("kind") or "").strip()
    name = str(subject.get("name") or "").strip()
    subject_namespace = str(subject.get("namespace") or binding_namespace or "").strip()
    if kind == "ServiceAccount" and name:
        return f"system:serviceaccount:{subject_namespace}:{name}"
    if kind and name:
        return f"{kind.lower()}:{name}"
    return name or kind or "unknown-subject"


rbac_bindings = []
for scope, doc in (("namespace", role_bindings_doc), ("cluster", clusterrolebindings_doc)):
    for binding in items(doc):
        metadata = binding.get("metadata") or {}
        role_ref = binding.get("roleRef") or {}
        binding_namespace = metadata.get("namespace")
        subjects = binding.get("subjects") or []
        if not subjects:
            subjects = [{"kind": "Unknown", "name": "unknown-subject"}]
        for subject in subjects:
            rbac_bindings.append(
                {
                    "scope": scope,
                    "namespace": binding_namespace if scope == "namespace" else None,
                    "subject": subject_string(subject, binding_namespace),
                    "roleRef": role_ref.get("name"),
                }
            )

rbac_roles = []
for scope, doc in (("namespace", roles_doc), ("cluster", clusterroles_doc)):
    for role in items(doc):
        metadata = role.get("metadata") or {}
        rbac_roles.append(
            {
                "scope": scope,
                "namespace": metadata.get("namespace") if scope == "namespace" else None,
                "name": metadata.get("name"),
                "rules": role.get("rules") or [],
            }
        )

workload_specs = []
workload_rollout_status = []


def add_workload_specs(doc, kind_name, pod_spec_selector):
    for workload in items(doc):
        metadata = workload.get("metadata") or {}
        spec = workload.get("spec") or {}
        pod_spec = pod_spec_selector(spec)
        if not pod_spec:
            continue
        workload_specs.append(
            {
                "namespace": metadata.get("namespace"),
                "name": metadata.get("name"),
                "kind": kind_name,
                "pod_spec": pod_spec,
            }
        )


add_workload_specs(deployments_doc, "Deployment", lambda spec: ((spec.get("template") or {}).get("spec") or {}))
add_workload_specs(statefulsets_doc, "StatefulSet", lambda spec: ((spec.get("template") or {}).get("spec") or {}))
add_workload_specs(daemonsets_doc, "DaemonSet", lambda spec: ((spec.get("template") or {}).get("spec") or {}))
add_workload_specs(jobs_doc, "Job", lambda spec: ((spec.get("template") or {}).get("spec") or {}))
add_workload_specs(cronjobs_doc, "CronJob", lambda spec: ((((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}))


def add_rollout_status(doc, kind_name):
    for workload in items(doc):
        metadata = workload.get("metadata") or {}
        spec = workload.get("spec") or {}
        status = workload.get("status") or {}
        desired_replicas = None
        ready_replicas = None
        available_replicas = None
        updated_replicas = None
        unavailable_replicas = None

        if kind_name in {"Deployment", "StatefulSet"}:
            desired_replicas = int(spec.get("replicas") or 0)
            ready_replicas = int(status.get("readyReplicas") or 0)
            available_replicas = int(status.get("availableReplicas") or 0)
            updated_replicas = int(status.get("updatedReplicas") or 0)
            unavailable_replicas = int(status.get("unavailableReplicas") or max(desired_replicas - available_replicas, 0))
        elif kind_name == "DaemonSet":
            desired_replicas = int(status.get("desiredNumberScheduled") or 0)
            ready_replicas = int(status.get("numberReady") or 0)
            available_replicas = int(status.get("numberAvailable") or 0)
            updated_replicas = int(status.get("updatedNumberScheduled") or 0)
            unavailable_replicas = int(status.get("numberUnavailable") or max(desired_replicas - available_replicas, 0))

        workload_rollout_status.append(
            {
                "namespace": metadata.get("namespace"),
                "name": metadata.get("name"),
                "kind": kind_name,
                "desired_replicas": desired_replicas,
                "ready_replicas": ready_replicas,
                "available_replicas": available_replicas,
                "updated_replicas": updated_replicas,
                "unavailable_replicas": unavailable_replicas,
                "generation": metadata.get("generation"),
                "observed_generation": status.get("observedGeneration"),
            }
        )


add_rollout_status(deployments_doc, "Deployment")
add_rollout_status(statefulsets_doc, "StatefulSet")
add_rollout_status(daemonsets_doc, "DaemonSet")

replicaset_owner = {}
for replica_set in items(replicasets_doc):
    metadata = replica_set.get("metadata") or {}
    owner = first_owner(metadata) or {}
    if owner.get("kind") == "Deployment":
        replicaset_owner[(metadata.get("namespace"), metadata.get("name"))] = (
            "Deployment",
            owner.get("name"),
        )

job_owner = {}
for job in items(jobs_doc):
    metadata = job.get("metadata") or {}
    owner = first_owner(metadata) or {}
    if owner.get("kind") == "CronJob":
        job_owner[(metadata.get("namespace"), metadata.get("name"))] = ("CronJob", owner.get("name"))


def pod_status_and_restarts(pod):
    status = pod.get("status") or {}
    container_statuses = status.get("containerStatuses") or []
    restarts = 0
    for container_status in container_statuses:
        restarts += int(container_status.get("restartCount") or 0)
        state = container_status.get("state") or {}
        waiting = state.get("waiting") or {}
        if waiting.get("reason"):
            return waiting.get("reason"), restarts
        terminated = state.get("terminated") or {}
        if terminated.get("reason"):
            return terminated.get("reason"), restarts
    return status.get("phase") or "Unknown", restarts


def status_rank(value):
    if value == "CrashLoopBackOff":
        return 100
    if value not in {"Running", "Succeeded"}:
        return 50
    if value == "Running":
        return 10
    return 0


def log_excerpt_candidates(pod, workload_kind, workload_name):
    metadata = pod.get("metadata") or {}
    status = pod.get("status") or {}
    namespace_value = metadata.get("namespace")
    pod_name = metadata.get("name")
    if not namespace_value or not pod_name:
        return []

    candidates = []
    for container_status in status.get("containerStatuses") or []:
        container_name = as_text(container_status.get("name"))
        if container_name is None:
            continue

        restart_count = int(container_status.get("restartCount") or 0)
        state = container_status.get("state") or {}
        waiting = state.get("waiting") or {}
        terminated = state.get("terminated") or {}
        last_state = container_status.get("lastState") or {}
        last_terminated = last_state.get("terminated") or {}

        waiting_reason = as_text(waiting.get("reason"))
        terminated_reason = as_text(terminated.get("reason"))
        previous_reason = as_text(last_terminated.get("reason"))
        reason = waiting_reason or terminated_reason or previous_reason or ("restart-loop" if restart_count > 0 else None)
        if reason is None:
            continue
        if waiting_reason in {"ImagePullBackOff", "ErrImagePull", "ContainerCreating", "PodInitializing"}:
            continue

        capture_previous = bool(previous_reason or terminated_reason or waiting_reason == "CrashLoopBackOff" or restart_count > 0)
        priority = log_priority(reason, restart_count)
        if priority <= 0:
            continue

        candidates.append(
            {
                "namespace": namespace_value,
                "pod_name": pod_name,
                "container_name": container_name,
                "workload_kind": workload_kind,
                "workload_name": workload_name,
                "reason": reason,
                "restarts": restart_count,
                "priority": priority,
                "previous": capture_previous,
            }
        )

    return candidates


def run_kubectl_logs(namespace_value, pod_name, container_name, previous):
    command = [kubectl_bin]
    if explicit_context:
        command.extend(["--context", explicit_context])
    command.extend(
        [
            "logs",
            "-n",
            namespace_value,
            pod_name,
            "-c",
            container_name,
            "--tail",
            "40",
            "--timestamps",
        ]
    )
    if previous:
        command.append("--previous")

    result = subprocess.run(
        command,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None

    raw_lines = [line.rstrip() for line in result.stdout.splitlines() if line.strip()]
    if not raw_lines:
        return None

    normalized_lines = []
    for line in raw_lines[-24:]:
        if len(line) > 240:
            normalized_lines.append(f"{line[:237]}...")
        else:
            normalized_lines.append(line)

    return {
        "excerpt_lines": normalized_lines,
        "line_count": len(raw_lines),
        "truncated": len(raw_lines) > len(normalized_lines),
    }


workload_status = {}
log_candidates = []
for pod in items(pods_doc):
    metadata = pod.get("metadata") or {}
    namespace_value = metadata.get("namespace")
    owner = first_owner(metadata) or {}
    owner_kind = owner.get("kind")
    owner_name = owner.get("name")

    if owner_kind == "ReplicaSet":
        owner_kind, owner_name = replicaset_owner.get((namespace_value, owner_name), ("ReplicaSet", owner_name))
    elif owner_kind == "Job":
        owner_kind, owner_name = job_owner.get((namespace_value, owner_name), ("Job", owner_name))
    elif not owner_kind or not owner_name:
        owner_kind, owner_name = "Pod", metadata.get("name")

    status_value, restarts = pod_status_and_restarts(pod)
    key = (namespace_value, owner_name, owner_kind)
    current = workload_status.get(key)
    candidate = {
        "namespace": namespace_value,
        "name": owner_name,
        "kind": owner_kind,
        "status": status_value,
        "restarts": restarts,
    }
    if current is None:
        workload_status[key] = candidate
    elif status_rank(candidate["status"]) > status_rank(current["status"]):
        workload_status[key] = candidate
    elif candidate["status"] == current["status"] and candidate["restarts"] > current["restarts"]:
        workload_status[key] = candidate

    log_candidates.extend(log_excerpt_candidates(pod, owner_kind, owner_name))

unhealthy_workload_log_excerpts = []
seen_log_keys = set()
for candidate in sorted(log_candidates, key=lambda row: (-row["priority"], -(row["restarts"] or 0), row["namespace"], row["pod_name"], row["container_name"]))[:6]:
    key = (
        candidate["namespace"],
        candidate["pod_name"],
        candidate["container_name"],
        candidate["previous"],
        candidate["reason"],
    )
    if key in seen_log_keys:
        continue

    excerpt = run_kubectl_logs(
        candidate["namespace"],
        candidate["pod_name"],
        candidate["container_name"],
        candidate["previous"],
    )
    if excerpt is None and candidate["previous"]:
        excerpt = run_kubectl_logs(
            candidate["namespace"],
            candidate["pod_name"],
            candidate["container_name"],
            False,
        )
        candidate = {**candidate, "previous": False}
    if excerpt is None:
        continue

    unhealthy_workload_log_excerpts.append(
        {
            "namespace": candidate["namespace"],
            "workload_kind": candidate["workload_kind"],
            "workload_name": candidate["workload_name"],
            "pod_name": candidate["pod_name"],
            "container_name": candidate["container_name"],
            "reason": candidate["reason"],
            "restarts": candidate["restarts"],
            "previous": candidate["previous"],
            **excerpt,
        }
    )
    seen_log_keys.add(
        (
            candidate["namespace"],
            candidate["pod_name"],
            candidate["container_name"],
            candidate["previous"],
            candidate["reason"],
        )
    )

documents = [
    {
        "path": "network/services.json",
        "kind": "service-exposure",
        "media_type": "application/json",
        "content": json.dumps(sorted(service_exposure, key=lambda row: (row.get("namespace") or "", row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "network/network-policies.json",
        "kind": "network-policies",
        "media_type": "application/json",
        "content": json.dumps(sorted(network_policies, key=lambda row: (row.get("namespace") or "", row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "rbac/bindings.json",
        "kind": "rbac-bindings",
        "media_type": "application/json",
        "content": json.dumps(sorted(rbac_bindings, key=lambda row: (row.get("scope") or "", row.get("namespace") or "", row.get("subject") or "", row.get("roleRef") or "")), separators=(",", ":")),
    },
    {
        "path": "rbac/roles.json",
        "kind": "rbac-roles",
        "media_type": "application/json",
        "content": json.dumps(sorted(rbac_roles, key=lambda row: (row.get("scope") or "", row.get("namespace") or "", row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "cluster/node-health.json",
        "kind": "node-health",
        "media_type": "application/json",
        "content": json.dumps(sorted(node_health, key=lambda row: (row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "autoscaling/horizontal-pod-autoscalers.json",
        "kind": "horizontal-pod-autoscalers",
        "media_type": "application/json",
        "content": json.dumps(sorted(hpa_state, key=lambda row: (row.get("namespace") or "", row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "policy/pod-disruption-budgets.json",
        "kind": "pod-disruption-budgets",
        "media_type": "application/json",
        "content": json.dumps(sorted(pdb_state, key=lambda row: (row.get("namespace") or "", row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "quotas/resource-quotas.json",
        "kind": "resource-quotas",
        "media_type": "application/json",
        "content": json.dumps(sorted(resource_quota_state, key=lambda row: (row.get("namespace") or "", row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "quotas/limit-ranges.json",
        "kind": "limit-ranges",
        "media_type": "application/json",
        "content": json.dumps(sorted(limit_range_state, key=lambda row: (row.get("namespace") or "", row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "storage/persistent-volume-claims.json",
        "kind": "persistent-volume-claims",
        "media_type": "application/json",
        "content": json.dumps(sorted(persistent_volume_claim_state, key=lambda row: (row.get("namespace") or "", row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "storage/persistent-volumes.json",
        "kind": "persistent-volumes",
        "media_type": "application/json",
        "content": json.dumps(sorted(persistent_volume_state, key=lambda row: (row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "events/warning-events.json",
        "kind": "warning-events",
        "media_type": "application/json",
        "content": json.dumps(
            sorted(
                warning_events,
                key=lambda row: (
                    row.get("last_timestamp") or "",
                    row.get("namespace") or "",
                    row.get("involved_kind") or "",
                    row.get("involved_name") or "",
                    row.get("reason") or "",
                ),
            ),
            separators=(",", ":"),
        ),
    },
    {
        "path": "logs/unhealthy-workload-excerpts.json",
        "kind": "unhealthy-workload-log-excerpts",
        "media_type": "application/json",
        "content": json.dumps(
            sorted(
                unhealthy_workload_log_excerpts,
                key=lambda row: (
                    row.get("namespace") or "",
                    row.get("workload_kind") or "",
                    row.get("workload_name") or "",
                    row.get("pod_name") or "",
                    row.get("container_name") or "",
                    "1" if row.get("previous") else "0",
                ),
            ),
            separators=(",", ":"),
        ),
    },
    {
        "path": "metrics/pod-top.json",
        "kind": "pod-top",
        "media_type": "application/json",
        "content": json.dumps(sorted(pod_top, key=lambda row: (row.get("namespace") or "", row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "metrics/node-top.json",
        "kind": "node-top",
        "media_type": "application/json",
        "content": json.dumps(sorted(node_top, key=lambda row: (row.get("name") or "")), separators=(",", ":")),
    },
    {
        "path": "workloads/specs.json",
        "kind": "workload-specs",
        "media_type": "application/json",
        "content": json.dumps(sorted(workload_specs, key=lambda row: (row.get("namespace") or "", row.get("name") or "", row.get("kind") or "")), separators=(",", ":")),
    },
    {
        "path": "workloads/status.json",
        "kind": "workload-status",
        "media_type": "application/json",
        "content": json.dumps(sorted(workload_status.values(), key=lambda row: (row.get("namespace") or "", row.get("name") or "", row.get("kind") or "")), separators=(",", ":")),
    },
    {
        "path": "workloads/rollout-status.json",
        "kind": "workload-rollout-status",
        "media_type": "application/json",
        "content": json.dumps(sorted(workload_rollout_status, key=lambda row: (row.get("namespace") or "", row.get("name") or "", row.get("kind") or "")), separators=(",", ":")),
    },
]

manifest = {
    "schema_version": "kubernetes-bundle.v1",
    "cluster": {
        "name": resolved_cluster_name,
        "provider": provider,
    },
    "scope": {
        "level": scope_level,
        "namespace": namespace if scope_level == "namespace" else None,
    },
    "collected_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "collector": {
        "type": "signalforge-collectors",
        "version": collector_version,
    },
    "documents": documents,
}

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

echo "Wrote $OUTPUT_PATH"
