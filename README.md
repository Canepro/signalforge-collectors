# SignalForge Collectors

Collector **implementations** for [SignalForge](https://github.com/Canepro/signalforge) — scripts that gather infrastructure evidence on or near the target. SignalForge analyzes the artifacts; this repo produces them.

| Repo | Role |
|------|------|
| **[signalforge](https://github.com/Canepro/signalforge)** | Control plane: ingestion, analysis, UI, APIs |
| **signalforge-collectors** (this repo) | Collector scripts that run on or near the target |
| **[signalforge-agent](https://github.com/Canepro/signalforge-agent)** | Execution-plane agent: heartbeat, poll, claim, run these collectors, upload artifacts |

## Purpose

This toolkit provides scripts to:
- collect Linux host audit evidence
- collect runtime-oriented container diagnostics
- collect normalized Kubernetes evidence bundles
- push those artifacts into SignalForge over the external submit contract
- compare Linux audit snapshots to detect changes

Good fits:
- initial server security audits
- container runtime posture checks
- Kubernetes evidence capture for diagnostics and drift review
- compliance and documentation
- change tracking in production environments

## Features

- **Linux host audit**: System identity, networking, users, SSH config, firewall rules, installed packages, disk and memory usage, running services, and recent errors
- **Container diagnostics**: Runtime, identity, ports, privilege signals, mounts, secrets, and root filesystem posture for one container
- **Kubernetes bundle export**: Normalized `kubernetes-bundle.v1` manifest built from `kubectl` JSON
- **Push-first submission**: One wrapper for multipart upload and ingestion metadata
- **Differential analysis**: Compare Linux audit snapshots to highlight changes

## Usage

### Clone the Repository

```bash
git clone https://github.com/Canepro/signalforge-collectors.git
cd signalforge-collectors
```

### Run Initial Audit

```bash
./first-audit.sh
```

This will:
1. Collect comprehensive system information
2. Save results to `server_audit_YYYYMMDD_HHMMSS.log`
3. Display a formatted summary in the terminal

### Collect Container Diagnostics

```bash
./collect-container-diagnostics.sh --container payments-api
```

This writes a `container_diagnostics_<container>_<timestamp>.txt` artifact in the text format SignalForge already accepts as `container-diagnostics`.

Useful options:

```bash
./collect-container-diagnostics.sh --runtime podman --container payments-api --output ./payments-container.txt
./submit-to-signalforge.sh --file ./payments-container.txt --artifact-type container-diagnostics --target-id 'container-workload:host-a:podman:payments-api' --source-label 'signalforge-collectors:collect-container-diagnostics.sh'
```

### Collect Kubernetes Evidence

```bash
./collect-kubernetes-bundle.sh --context prod-eu-1 --namespace payments
```

This writes a `kubernetes_bundle_<scope>_<timestamp>.json` artifact in the `kubernetes-bundle.v1` format expected by SignalForge.

Useful options:

```bash
./collect-kubernetes-bundle.sh --scope cluster --provider aks --output ./cluster-bundle.json
./submit-to-signalforge.sh --file ./cluster-bundle.json --artifact-type kubernetes-bundle --target-id 'cluster:aks-prod-eu-1' --source-label 'signalforge-collectors:collect-kubernetes-bundle.sh'
./submit-to-signalforge.sh --file ./payments-bundle.json --artifact-type kubernetes-bundle --target-id 'cluster:aks-prod-eu-1:namespace:payments' --source-label 'signalforge-collectors:collect-kubernetes-bundle.sh'
```

Kubernetes collection is currently an honest push-first path. It does not imply that every environment already has a job-driven agent deployment for Kubernetes collection.

### Push audit to SignalForge (reference collector)

**SignalForge** (separate product repo) analyzes audit logs; it does **not** run collectors on your hosts. This repo includes a **narrow reference path** that matches the external multipart contract (`POST /api/runs`):

```bash
chmod +x submit-to-signalforge.sh   # once
export SIGNALFORGE_URL=http://localhost:3000   # must match where SignalForge listens (use the app URL, e.g. :3001 if Next picked another port)
./submit-to-signalforge.sh
# or submit an existing log without re-running the audit:
./submit-to-signalforge.sh --file ./server_audit_20250115_143210.log
```

Optional:

```bash
./submit-to-signalforge.sh --url http://127.0.0.1:3000 --target-id my-fleet-key
./submit-to-signalforge.sh --file ./artifact.json --artifact-type kubernetes-bundle --source-label custom-k8s-export
```

The script runs `first-audit.sh` by default, or uploads an existing artifact with explicit metadata (`artifact_type`, `target_identifier`, `source_label`, `collector_type`, `collector_version`, `collected_at`). Linux, container, and Kubernetes collectors in this repo all reuse that same push path.

See SignalForge **`docs/external-submit.md`** in that repository for field definitions. In the SignalForge UI, **Collect externally** shows a copy-paste block with your current app origin as `SIGNALFORGE_URL`.

### Job-driven collection (via signalforge-agent)

For **automated** collection, use [signalforge-agent](https://github.com/Canepro/signalforge-agent) — a thin execution-plane runtime that:

1. Authenticates with a **source-bound** agent token from SignalForge
2. Heartbeats and polls for queued **collection jobs**
3. Runs a collector from **this repo**
4. Uploads the artifact back to SignalForge automatically

The agent orchestrates the HTTP lifecycle (claim → start → collect → upload → fail); this repo provides only the collector scripts. The current agent can now dispatch Linux, container, and Kubernetes collectors from a host install, and Phase 9 job scope now maps directly to collector inputs where available. In practice that means:

- Linux host collection is the cleanest end-to-end job-driven path today
- container collection can take an explicit target and runtime per job; `SIGNALFORGE_CONTAINER_REF` remains only as a legacy fallback
- Kubernetes collection can take an explicit `--context` or `SIGNALFORGE_KUBERNETES_CONTEXT`, so job-driven callers do not need to rely on the ambient `kubectl current-context`
- container image and Kubernetes-native agent deployment forms are still future packaging work, not shipped artifacts today

```bash
# On the host, with signalforge-agent and signalforge-collectors both checked out:
export SIGNALFORGE_URL=http://your-signalforge:3000
export SIGNALFORGE_AGENT_TOKEN='<token from enrollment>'
export SIGNALFORGE_AGENT_INSTANCE_ID="$(hostname)-agent-1"
export SIGNALFORGE_COLLECTORS_DIR=/path/to/signalforge-collectors

cd /path/to/signalforge-agent
bun run src/cli.ts once    # one job, then exit
bun run src/cli.ts run     # poll loop
```

### Compare Audits

After running multiple audits, compare them to detect changes:

```bash
./diff-audit.sh server_audit_20250101_120000.log server_audit_20250102_120000.log
```

This highlights:
- New or removed users
- Changed services/processes
- Firewall rule modifications
- Disk usage changes
- Package installations/removals
- Configuration drift

## Sample Output

```
╔════════════════════════════════════════════════════════════════╗
║              SERVER AUDIT REPORT                               ║
║              2025-01-15 14:32:10 UTC                          ║
╚════════════════════════════════════════════════════════════════╝

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[SYSTEM IDENTITY]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Hostname: web-server-prod-01
OS: Ubuntu 22.04.3 LTS
Kernel: 5.15.0-89-generic
Uptime: 42 days, 3:15

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[NETWORK CONFIGURATION]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
eth0: 192.168.1.100/24
Gateway: 192.168.1.1
DNS: 8.8.8.8, 8.8.4.4

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[DISK USAGE]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
/dev/sda1: 45% (120G / 500G)
/dev/sdb1: 78% (780G / 1.0T)

[... additional sections ...]

Audit complete. Full log saved to: server_audit_20250115_143210.log
```

## Requirements

- Bash 4.0+
- Python 3 for JSON transformation in the container and Kubernetes collectors
- Standard Linux utilities (`systemctl`, `ss`, `iptables` or `ufw`, `df`, etc.) for the Linux host audit
- A supported container runtime (`podman` or `docker`) for `collect-container-diagnostics.sh`
- `kubectl` with read access to the target cluster or namespace for `collect-kubernetes-bundle.sh`
- Root or sudo access recommended for complete Linux host audit coverage

## File Structure

```
signalforge-collectors/
├── README.md                  # This file
├── first-audit.sh             # Main audit script
├── collect-container-diagnostics.sh  # Container diagnostics exporter
├── collect-kubernetes-bundle.sh      # Kubernetes bundle exporter
├── submit-to-signalforge.sh   # Reference push to SignalForge (optional)
├── diff-audit.sh              # Differential comparison script
├── tests/
│   ├── validate-submit-script.sh    # Static checks for submit script
│   └── validate-collector-scripts.sh # Mocked checks for container and Kubernetes collectors
├── .gitignore                 # Excludes generated logs
├── examples/                  # Sample audit logs
│   └── sample_audit.log
└── .github/
    └── workflows/
        └── lint.yml           # ShellCheck CI + submit-script checks
```

## Contributing

Contributions welcome! Please ensure:
- Scripts pass `shellcheck` validation
- Functions are well-commented
- New features include documentation updates

## License

MIT License - feel free to use and modify for your needs.
