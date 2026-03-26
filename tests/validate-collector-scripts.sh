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
    "HostConfig": {
      "Privileged": true,
      "NetworkMode": "host",
      "PidMode": "host",
      "CapAdd": ["NET_ADMIN", "SYS_ADMIN"],
      "ReadonlyRootfs": false,
      "SecurityOpt": []
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
grep -q '^published_ports: 8080:8080/tcp$' "$TMP_DIR/container.txt"
grep -q '^privileged: true$' "$TMP_DIR/container.txt"
grep -q '^host_network: true$' "$TMP_DIR/container.txt"
grep -q '^host_pid: true$' "$TMP_DIR/container.txt"
grep -q '^added_capabilities: NET_ADMIN, SYS_ADMIN$' "$TMP_DIR/container.txt"
grep -q '^secrets: /run/secrets/payments$' "$TMP_DIR/container.txt"

cat >"$TMP_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
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
{"items":[{"metadata":{"namespace":"payments","name":"payments-api"},"spec":{"template":{"spec":{"serviceAccountName":"payments-api","automountServiceAccountToken":true,"containers":[{"name":"api","image":"ghcr.io/acme/payments:v1","securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"readOnlyRootFilesystem":false}}]}}}}]}
JSON
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
assert "workload-specs" in kinds
assert "workload-status" in kinds
PY

echo "validate-collector-scripts: ok"
