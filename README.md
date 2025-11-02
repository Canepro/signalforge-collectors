# Server Audit Kit

A comprehensive toolkit for auditing fresh Linux servers and tracking configuration changes over time.

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
git clone https://github.com/YOUR_USERNAME/server-audit-kit.git
cd server-audit-kit
```

### Run Initial Audit

```bash
./first-audit.sh
```

This will:
1. Collect comprehensive system information
2. Save results to `server_audit_YYYYMMDD_HHMMSS.log`
3. Display a formatted summary in the terminal

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
server-audit-kit/
├── README.md              # This file
├── first-audit.sh         # Main audit script
├── diff-audit.sh          # Differential comparison script
├── .gitignore            # Excludes generated logs
├── examples/             # Sample audit logs
│   └── sample_audit.log
└── .github/
    └── workflows/
        └── lint.yml      # ShellCheck CI linting
```

## Contributing

Contributions welcome! Please ensure:
- Scripts pass `shellcheck` validation
- Functions are well-commented
- New features include documentation updates

## License

MIT License - feel free to use and modify for your needs.
