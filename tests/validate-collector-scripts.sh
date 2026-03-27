#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash -n collect-container-diagnostics.sh
bash -n collect-kubernetes-bundle.sh

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "inspect" && "${2:-}" == "payments-api" ]]; then
  cat <<'JSON'
[
  {
    "Id": "abcdef1234567890",
    "Name": "/payments-api",
    "Config": {
      "Image": "ghcr.io/acme/payments:latest",
      "User": ""
    },
    "RestartCount": 4,
    "HostConfig": {
      "Privileged": true,
      "NetworkMode": "host",
      "PidMode": "host",
      "CapAdd": ["NET_ADMIN", "SYS_ADMIN"],
      "Memory": 0,
      "MemoryReservation": 134217728,
      "ReadonlyRootfs": false,
      "SecurityOpt": []
    },
    "State": {
      "Status": "restarting",
      "OOMKilled": true,
      "ExitCode": 137,
      "Health": {
        "Status": "unhealthy"
      }
    },
    "Mounts": [
      {
        "Type": "bind",
        "Source": "/var/run/docker.sock",
        "Destination": "/var/run/docker.sock",
        "RW": true
      },
      {
        "Type": "volume",
        "Name": "payments-data",
        "Destination": "/var/lib/payments",
        "RW": true
      },
      {
        "Type": "bind",
        "Source": "/srv/secrets/payments",
        "Destination": "/run/secrets/payments",
        "RW": false
      }
    ],
    "NetworkSettings": {
      "Ports": {
        "8080/tcp": [
          {
            "HostIp": "0.0.0.0",
            "HostPort": "8080"
          }
        ]
      }
    }
  }
]
JSON
  exit 0
fi
if [[ "${1:-}" == "stats" && "${2:-}" == "--no-stream" && "${3:-}" == "--format" && "${4:-}" == "json" && "${5:-}" == "payments-api" ]]; then
  cat <<'JSON'
[
  {
    "id": "abcdef123456",
    "name": "payments-api",
    "cpu_percent": "97.40%",
    "mem_usage": "421.0MB / 512.0MB",
    "mem_percent": "82.20%",
    "pids": "27"
  }
]
JSON
  exit 0
fi
echo "unexpected podman invocation: $*" >&2
exit 1
EOF
chmod +x "$TMP_DIR/podman"

PATH="$TMP_DIR:$PATH" ./collect-container-diagnostics.sh \
  --runtime podman \
  --container payments-api \
  --hostname collector-host \
  --output "$TMP_DIR/container.txt"

grep -q '^=== container-diagnostics ===$' "$TMP_DIR/container.txt"
grep -q '^runtime: podman$' "$TMP_DIR/container.txt"
grep -q '^container_name: payments-api$' "$TMP_DIR/container.txt"
grep -q '^state_status: restarting$' "$TMP_DIR/container.txt"
grep -q '^health_status: unhealthy$' "$TMP_DIR/container.txt"
grep -q '^restart_count: 4$' "$TMP_DIR/container.txt"
grep -q '^oom_killed: true$' "$TMP_DIR/container.txt"
grep -q '^exit_code: 137$' "$TMP_DIR/container.txt"
grep -q '^published_ports: 8080:8080/tcp$' "$TMP_DIR/container.txt"
grep -q '^privileged: true$' "$TMP_DIR/container.txt"
grep -q '^host_network: true$' "$TMP_DIR/container.txt"
grep -q '^host_pid: true$' "$TMP_DIR/container.txt"
grep -q '^added_capabilities: NET_ADMIN, SYS_ADMIN$' "$TMP_DIR/container.txt"
grep -q '^secrets: /run/secrets/payments$' "$TMP_DIR/container.txt"
grep -q '^memory_limit_bytes: 0$' "$TMP_DIR/container.txt"
grep -q '^memory_reservation_bytes: 134217728$' "$TMP_DIR/container.txt"
grep -q '^cpu_percent: 97.40$' "$TMP_DIR/container.txt"
grep -q '^memory_percent: 82.20$' "$TMP_DIR/container.txt"
grep -q '^pid_count: 27$' "$TMP_DIR/container.txt"

cat >"$TMP_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  '--context prod-eu-1 config view -o json')
    cat <<'JSON'
{
  "current-context": "payments-context",
  "contexts": [
    {
      "name": "payments-context",
      "context": {
        "cluster": "aks-payments-prod",
        "namespace": "payments"
      }
    },
    {
      "name": "prod-eu-1",
      "context": {
        "cluster": "aks-payments-prod",
        "namespace": "payments"
      }
    }
  ],
  "clusters": [
    {
      "name": "aks-payments-prod",
      "cluster": {
        "server": "https://example.invalid"
      }
    }
  ]
}
JSON
    ;;
  'config view -o json')
    cat <<'JSON'
{
  "current-context": "payments-context",
  "contexts": [
    {
      "name": "payments-context",
      "context": {
        "cluster": "aks-payments-prod",
        "namespace": "payments"
      }
    }
  ],
  "clusters": [
    {
      "name": "aks-payments-prod",
      "cluster": {
        "server": "https://example.invalid"
      }
    }
  ]
}
JSON
    ;;
  '--context prod-eu-1 get services -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-public"},"spec":{"type":"LoadBalancer"},"status":{"loadBalancer":{"ingress":[{"ip":"203.0.113.10"}]}}}]}
JSON
    ;;
  '--context prod-eu-1 get networkpolicies -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"default-deny"}}]}
JSON
    ;;
  '--context prod-eu-1 get rolebindings -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-admin"},"roleRef":{"name":"payments-admin"},"subjects":[{"kind":"ServiceAccount","namespace":"payments","name":"payments-api"}]}]}
JSON
    ;;
  '--context prod-eu-1 get roles -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-admin"},"rules":[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]}]}]}
JSON
    ;;
  '--context prod-eu-1 get deployments -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-api","generation":4},"spec":{"replicas":3,"template":{"spec":{"serviceAccountName":"payments-api","automountServiceAccountToken":true,"containers":[{"name":"api","image":"ghcr.io/acme/payments:v1","securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"readOnlyRootFilesystem":false}}]}}},"status":{"observedGeneration":4,"readyReplicas":1,"availableReplicas":1,"updatedReplicas":2,"unavailableReplicas":2}}]}
JSON
    ;;
  '--context prod-eu-1 get events -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","creationTimestamp":"2026-03-26T10:00:00Z"},"type":"Warning","reason":"FailedScheduling","message":"0/3 nodes are available: 3 Insufficient memory.","count":4,"involvedObject":{"kind":"Pod","namespace":"payments","name":"payments-api-abc123"}},{"metadata":{"namespace":"payments","creationTimestamp":"2026-03-26T10:05:00Z"},"type":"Warning","reason":"ImagePullBackOff","message":"Back-off pulling image ghcr.io/acme/payments:bad","count":2,"involvedObject":{"kind":"Pod","namespace":"payments","name":"payments-api-abc123"}}]}
JSON
    ;;
  '--context prod-eu-1 get nodes -o json')
    cat <<'JSON'
{"items":[{"metadata":{"name":"aks-system-000001"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"False"},{"type":"MemoryPressure","status":"True"},{"type":"DiskPressure","status":"False"},{"type":"PIDPressure","status":"False"}]}}]}
JSON
    ;;
  '--context prod-eu-1 top pods -n payments --no-headers')
    cat <<'EOF_TOP_PODS'
payments-api-abc123 412m 486Mi
EOF_TOP_PODS
    ;;
  '--context prod-eu-1 top nodes --no-headers')
    cat <<'EOF_TOP_NODES'
aks-system-000001 1850m 92% 14900Mi 91%
EOF_TOP_NODES
    ;;
  '--context prod-eu-1 get statefulsets -n payments -o json'|'--context prod-eu-1 get daemonsets -n payments -o json'|'--context prod-eu-1 get jobs -n payments -o json'|'--context prod-eu-1 get cronjobs -n payments -o json')
    printf '%s\n' '{"items":[]}'
    ;;
  '--context prod-eu-1 get pods -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-api-abc123","ownerReferences":[{"kind":"ReplicaSet","name":"payments-api-67d8f7"}]},"status":{"phase":"Running","containerStatuses":[{"restartCount":3,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}
JSON
    ;;
  '--context prod-eu-1 get replicasets -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-api-67d8f7","ownerReferences":[{"kind":"Deployment","name":"payments-api"}]}}]}
JSON
    ;;
  '--context prod-eu-1 get clusterroles -o json'|'--context prod-eu-1 get clusterrolebindings -o json')
    printf '%s\n' '{"items":[]}'
    ;;
  '--context prod-eu-1 get horizontalpodautoscalers -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-api"},"spec":{"scaleTargetRef":{"kind":"Deployment","name":"payments-api"},"minReplicas":2,"maxReplicas":6,"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":60}}}]},"status":{"currentReplicas":4,"desiredReplicas":5,"currentCPUUtilizationPercentage":72,"conditions":[{"type":"AbleToScale","status":"True","reason":"Ready","message":"scaled"}],"currentMetrics":[{"type":"Resource","resource":{"name":"cpu","current":{"averageUtilization":72}}}]}}]}
JSON
    ;;
  '--context prod-eu-1 get poddisruptionbudgets -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-api-pdb"},"spec":{"minAvailable":"2"},"status":{"currentHealthy":3,"desiredHealthy":2,"disruptionsAllowed":1,"expectedPods":4}}]}
JSON
    ;;
  '--context prod-eu-1 get resourcequotas -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-quota"},"status":{"hard":{"pods":"10","requests.cpu":"4","requests.memory":"8Gi"},"used":{"pods":"6","requests.cpu":"2500m","requests.memory":"6Gi"}}}]}
JSON
    ;;
  '--context prod-eu-1 get limitranges -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-limits"},"spec":{"limits":[{"type":"Container","defaultRequest":{"cpu":"100m","memory":"128Mi"},"default":{"cpu":"500m","memory":"512Mi"}}]}}]}
JSON
    ;;
  '--context prod-eu-1 get persistentvolumeclaims -n payments -o json')
    if [[ "${SIGNALFORGE_TEST_STORAGE_FAILURES:-0}" == "1" ]]; then
      echo "forbidden: persistentvolumeclaims is unavailable" >&2
      exit 1
    fi
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-data"},"spec":{"storageClassName":"premium-ssd","volumeName":"pv-payments-data","accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem","resources":{"requests":{"storage":"20Gi"}}},"status":{"phase":"Bound","capacity":{"storage":"20Gi"},"conditions":[{"type":"FileSystemResizePending","status":"False"}]}}]}
JSON
    ;;
  '--context prod-eu-1 get persistentvolumes -o json')
    if [[ "${SIGNALFORGE_TEST_STORAGE_FAILURES:-0}" == "1" ]]; then
      echo "forbidden: persistentvolumes is unavailable" >&2
      exit 1
    fi
    cat <<'JSON'
{"items":[{"metadata":{"name":"pv-payments-data"},"spec":{"storageClassName":"premium-ssd","claimRef":{"namespace":"payments","name":"payments-data"},"accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem","capacity":{"storage":"20Gi"},"persistentVolumeReclaimPolicy":"Retain","csi":{"driver":"disk.csi.example.com"}},"status":{"phase":"Bound","capacity":{"storage":"20Gi"}}}]}
JSON
    ;;
  'get services -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-public"},"spec":{"type":"LoadBalancer"},"status":{"loadBalancer":{"ingress":[{"ip":"203.0.113.10"}]}}}]}
JSON
    ;;
  'get networkpolicies -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"default-deny"}}]}
JSON
    ;;
  'get rolebindings -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-admin"},"roleRef":{"name":"payments-admin"},"subjects":[{"kind":"ServiceAccount","namespace":"payments","name":"payments-api"}]}]}
JSON
    ;;
  'get roles -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-admin"},"rules":[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]}]}]}
JSON
    ;;
  'get deployments -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-api","generation":4},"spec":{"replicas":3,"template":{"spec":{"serviceAccountName":"payments-api","automountServiceAccountToken":true,"containers":[{"name":"api","image":"ghcr.io/acme/payments:v1","securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"readOnlyRootFilesystem":false}}]}}},"status":{"observedGeneration":4,"readyReplicas":1,"availableReplicas":1,"updatedReplicas":2,"unavailableReplicas":2}}]}
JSON
    ;;
  'get events -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","creationTimestamp":"2026-03-26T10:00:00Z"},"type":"Warning","reason":"FailedScheduling","message":"0/3 nodes are available: 3 Insufficient memory.","count":4,"involvedObject":{"kind":"Pod","namespace":"payments","name":"payments-api-abc123"}},{"metadata":{"namespace":"payments","creationTimestamp":"2026-03-26T10:05:00Z"},"type":"Warning","reason":"ImagePullBackOff","message":"Back-off pulling image ghcr.io/acme/payments:bad","count":2,"involvedObject":{"kind":"Pod","namespace":"payments","name":"payments-api-abc123"}}]}
JSON
    ;;
  'get nodes -o json')
    cat <<'JSON'
{"items":[{"metadata":{"name":"aks-system-000001"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"False"},{"type":"MemoryPressure","status":"True"},{"type":"DiskPressure","status":"False"},{"type":"PIDPressure","status":"False"}]}}]}
JSON
    ;;
  'top pods -n payments --no-headers')
    cat <<'EOF_TOP_PODS'
payments-api-abc123 412m 486Mi
EOF_TOP_PODS
    ;;
  'top nodes --no-headers')
    cat <<'EOF_TOP_NODES'
aks-system-000001 1850m 92% 14900Mi 91%
EOF_TOP_NODES
    ;;
  'get statefulsets -n payments -o json'|'get daemonsets -n payments -o json'|'get jobs -n payments -o json'|'get cronjobs -n payments -o json')
    printf '%s\n' '{"items":[]}'
    ;;
  'get pods -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-api-abc123","ownerReferences":[{"kind":"ReplicaSet","name":"payments-api-67d8f7"}]},"status":{"phase":"Running","containerStatuses":[{"restartCount":3,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}
JSON
    ;;
  'get replicasets -n payments -o json')
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"payments","name":"payments-api-67d8f7","ownerReferences":[{"kind":"Deployment","name":"payments-api"}]}}]}
JSON
    ;;
  'get clusterroles -o json'|'get clusterrolebindings -o json')
    printf '%s\n' '{"items":[]}'
    ;;
  *)
    echo "unexpected kubectl invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_DIR/kubectl"

PATH="$TMP_DIR:$PATH" ./collect-kubernetes-bundle.sh \
  --namespace payments \
  --context prod-eu-1 \
  --provider aks \
  --output "$TMP_DIR/kubernetes.json"

python3 - "$TMP_DIR/kubernetes.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

assert manifest["schema_version"] == "kubernetes-bundle.v1"
assert manifest["cluster"]["name"] == "aks-payments-prod"
assert manifest["cluster"]["provider"] == "aks"
assert manifest["scope"]["level"] == "namespace"
assert manifest["scope"]["namespace"] == "payments"

kinds = {doc["kind"] for doc in manifest["documents"]}
assert "service-exposure" in kinds
assert "network-policies" in kinds
assert "rbac-bindings" in kinds
assert "rbac-roles" in kinds
assert "node-health" in kinds
assert "warning-events" in kinds
assert "pod-top" in kinds
assert "node-top" in kinds
assert "workload-specs" in kinds
assert "workload-status" in kinds
assert "workload-rollout-status" in kinds
assert "horizontal-pod-autoscalers" in kinds
assert "pod-disruption-budgets" in kinds
assert "resource-quotas" in kinds
assert "limit-ranges" in kinds
assert "persistent-volume-claims" in kinds
assert "persistent-volumes" in kinds

docs = {doc["kind"]: json.loads(doc["content"]) for doc in manifest["documents"]}
assert docs["horizontal-pod-autoscalers"][0]["scale_target_kind"] == "Deployment"
assert docs["horizontal-pod-autoscalers"][0]["target_cpu_utilization_percentage"] == 60
assert docs["pod-disruption-budgets"][0]["min_available"] == "2"
assert docs["resource-quotas"][0]["resources"][0]["resource"] == "pods"
assert docs["resource-quotas"][0]["resources"][0]["used_ratio"] == 0.6
assert docs["limit-ranges"][0]["has_default_requests"] is True
assert docs["limit-ranges"][0]["has_default_limits"] is True
assert docs["node-health"][0]["name"] == "aks-system-000001"
assert docs["node-health"][0]["ready"] is False
assert docs["node-health"][0]["pressure_conditions"] == ["MemoryPressure"]
assert docs["warning-events"][0]["reason"] == "FailedScheduling"
assert docs["warning-events"][1]["reason"] == "ImagePullBackOff"
assert docs["persistent-volume-claims"][0]["name"] == "payments-data"
assert docs["persistent-volume-claims"][0]["bound"] is True
assert docs["persistent-volume-claims"][0]["requested_storage"] == "20Gi"
assert docs["persistent-volume-claims"][0]["capacity_storage"] == "20Gi"
assert docs["persistent-volumes"][0]["name"] == "pv-payments-data"
assert docs["persistent-volumes"][0]["claim_namespace"] == "payments"
assert docs["persistent-volumes"][0]["claim_name"] == "payments-data"
assert docs["persistent-volumes"][0]["reclaim_policy"] == "Retain"
assert docs["persistent-volumes"][0]["csi_driver"] == "disk.csi.example.com"
assert docs["pod-top"][0]["name"] == "payments-api-abc123"
assert docs["pod-top"][0]["memory"] == "486Mi"
assert docs["node-top"][0]["name"] == "aks-system-000001"
assert docs["node-top"][0]["cpu_percent"] == 92.0
assert docs["node-top"][0]["memory_percent"] == 91.0
assert docs["workload-rollout-status"][0]["name"] == "payments-api"
assert docs["workload-rollout-status"][0]["desired_replicas"] == 3
assert docs["workload-rollout-status"][0]["ready_replicas"] == 1
assert docs["workload-rollout-status"][0]["updated_replicas"] == 2
PY

SIGNALFORGE_TEST_STORAGE_FAILURES=1 PATH="$TMP_DIR:$PATH" ./collect-kubernetes-bundle.sh \
  --namespace payments \
  --context prod-eu-1 \
  --provider aks \
  --output "$TMP_DIR/kubernetes-storage-fallback.json"

python3 - "$TMP_DIR/kubernetes-storage-fallback.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

docs = {doc["kind"]: json.loads(doc["content"]) for doc in manifest["documents"]}
assert docs["persistent-volume-claims"] == []
assert docs["persistent-volumes"] == []
PY

echo "validate-collector-scripts: ok"
