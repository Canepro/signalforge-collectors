# SignalForge Collectors

Collector **implementations** for [SignalForge](https://github.com/Canepro/signalforge) — scripts that gather infrastructure evidence on a host. SignalForge analyzes the artifacts; this repo produces them.

| Repo | Role |
|------|------|
| **[signalforge](https://github.com/Canepro/signalforge)** | Control plane: ingestion, analysis, UI, APIs |
| **signalforge-collectors** (this repo) | Collector scripts that run on or near the target |
| **[signalforge-agent](https://github.com/Canepro/signalforge-agent)** | Execution-plane agent: heartbeat, poll, claim, run these collectors, upload artifacts |

## Purpose

This toolkit provides automated scripts to:
- Collect detailed system information (identity, network, users, security, services, resources)
- Save audit snapshots with timestamps
- Compare audits to detect changes (new users, modified services, disk usage trends)

Perfect for:
- Initial server security audits
- Configuration drift detection
- Compliance and documentation
- Change tracking in production environments

## Features

- **Comprehensive audit**: System identity, networking, users, SSH config, firewall rules, installed packages, disk/memory usage, running services, and recent errors
- **Timestamped logs**: Each audit saved with ISO 8601 timestamp
- **Beautiful terminal output**: Color-coded section headers for quick visual inspection
- **Differential analysis**: Compare any two audit logs to highlight changes
- **Modular design**: Clean, well-commented Bash functions

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

### Push audit to SignalForge (reference collector)

**SignalForge** (separate product repo) analyzes audit logs; it does **not** run collectors on your hosts. This repo includes a **narrow reference path** that matches the external multipart contract (`POST /api/runs`):

```bash
chmod +x submit-to-signalforge.sh   # once
export SIGNALFORGE_URL=http://localhost:3000   # must match where SignalForge listens (use the app URL, e.g. :3001 if Next picked another port)
./submit-to-signalforge.sh
# or submit an existing log without re-running the audit:
./submit-to-signalforge.sh --file ./server_audit_20250115_143210.log
```

Optional: `./submit-to-signalforge.sh --url http://127.0.0.1:3000 --target-id my-fleet-key`

The script runs `first-audit.sh` (unless `--file` is set), then uploads with ingestion metadata (`target_identifier`, `source_label`, `collector_type`, `collector_version`, `collected_at`). Same HTTP contract can be reused later for **Kubernetes bundles**, **container diagnostics**, **Windows/macOS** evidence, or other platforms — swap what produces the artifact; keep the push + metadata pattern.

See SignalForge **`docs/external-submit.md`** in that repository for field definitions. In the SignalForge UI, **Collect externally** shows a copy-paste block with your current app origin as `SIGNALFORGE_URL`.

### Job-driven collection (via signalforge-agent)

For **automated** collection, use [signalforge-agent](https://github.com/Canepro/signalforge-agent) — a thin execution-plane runtime that:

1. Authenticates with a **source-bound** agent token from SignalForge
2. Heartbeats and polls for queued **collection jobs**
3. Runs `first-audit.sh` from **this repo** on the host
4. Uploads the artifact back to SignalForge automatically

The agent orchestrates the HTTP lifecycle (claim → start → collect → upload → fail); this repo provides only the collector scripts. See the [signalforge-agent README](https://github.com/Canepro/signalforge-agent) for setup.

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
- Standard Linux utilities (systemctl, ss, iptables/ufw, df, etc.)
- Root or sudo access recommended for complete information

## File Structure

```
signalforge-collectors/
├── README.md                  # This file
├── first-audit.sh             # Main audit script
├── submit-to-signalforge.sh   # Reference push to SignalForge (optional)
├── diff-audit.sh              # Differential comparison script
├── tests/
│   └── validate-submit-script.sh  # Static checks for submit script
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
