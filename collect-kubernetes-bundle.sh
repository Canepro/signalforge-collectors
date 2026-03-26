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

if [[ -z "$OUTPUT_PATH" ]]; then
  TS="$(date -u '+%Y%m%d_%H%M%S')"
  if [[ "$SCOPE" == "namespace" ]]; then
    BASE_NAME="kubernetes_bundle_$(sanitize_name "$NAMESPACE")_${TS}.json"
  else
    BASE_NAME="kubernetes_bundle_cluster_${TS}.json"
  fi
  OUTPUT_PATH="./${BASE_NAME}"
fi

python3 - "$TMP_DIR" "$SCOPE" "$NAMESPACE" "$CLUSTER_NAME" "$PROVIDER" "$OUTPUT_PATH" "$COLLECTOR_VERSION" "$KUBECTL_CONTEXT" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

tmp_dir, scope_level, namespace, cluster_name_arg, provider_arg, output_path, collector_version, explicit_context = sys.argv[1:]


def load(name):
    path = os.path.join(tmp_dir, name)
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def items(doc):
    value = doc.get("items")
    return value if isinstance(value, list) else []


def first_owner(metadata):
    owners = metadata.get("ownerReferences") or []
    return owners[0] if owners else None


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


workload_status = {}
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
        continue
    if status_rank(candidate["status"]) > status_rank(current["status"]):
        workload_status[key] = candidate
        continue
    if candidate["status"] == current["status"] and candidate["restarts"] > current["restarts"]:
        workload_status[key] = candidate

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
