#!/bin/bash

################################################################################
# Server Audit Script
# Purpose: Collect comprehensive system information for security audits
# Output: Timestamped log file with system identity, network, users, services,
#         security configuration, and resource usage
################################################################################

set -euo pipefail

# Color codes for terminal output
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'
readonly SECTION_DIVIDER='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

if [ -t 1 ]; then
    readonly IS_TTY=1
else
    readonly IS_TTY=0
fi

# Generate timestamped log filename
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly TIMESTAMP
readonly LOG_FILE="server_audit_${TIMESTAMP}.log"

################################################################################
# Helper Functions
################################################################################

# Print a line to the terminal only.
terminal_line() {
    printf '%b\n' "$1"
}

# Print a plain text line to the report.
report_line() {
    printf '%s\n' "$1" >> "$LOG_FILE"
}

# Announce command progress without polluting the report with ANSI escape codes.
announce_step() {
    local description="$1"

    if [ "$IS_TTY" -eq 1 ]; then
        terminal_line "${GREEN}collecting${NC} ${description}"
    else
        printf '[collect] %s\n' "$description"
    fi
}

# Append a command block to the report in a stable plain-text shape.
report_command_block() {
    local description="$1"
    local status="$2"
    local output="$3"

    report_line "${description}:"
    if [ "$status" -ne 0 ]; then
        report_line "Command failed (exit ${status})"
    fi

    if [ -n "$output" ]; then
        printf '%s\n' "$output" >> "$LOG_FILE"
    else
        report_line "(no output)"
    fi

    report_line ""
}

# Print section header to both log and terminal
print_header() {
    local title="$1"
    
    {
        echo ""
        echo "$SECTION_DIVIDER"
        echo "[$title]"
        echo "$SECTION_DIVIDER"
    } >> "$LOG_FILE"
    
    echo ""
    if [ "$IS_TTY" -eq 1 ]; then
        terminal_line "${BOLD}${CYAN}${title}${NC}"
    else
        printf '[section] %s\n' "$title"
    fi
}

# Execute command and capture output to both log and terminal
run_command() {
    local description="$1"
    shift
    local output
    local status=0
    
    announce_step "$description"
    
    if output=$("$@" 2>&1); then
        status=0
    else
        status=$?
    fi

    report_command_block "$description" "$status" "$output"
}

# Execute shell constructs such as pipelines, redirects, and fallbacks safely.
run_shell_command() {
    local description="$1"
    local command="$2"
    local output
    local status=0

    announce_step "$description"

    if output=$(bash -o pipefail -c "$command" 2>&1); then
        status=0
    else
        status=$?
    fi

    report_command_block "$description" "$status" "$output"
}

# Safe command execution (doesn't fail if command not found)
safe_run() {
    local description="$1"
    shift
    
    if command -v "$1" &> /dev/null; then
        run_command "$description" "$@"
    else
        announce_step "$description"
        report_command_block \
            "$description" \
            127 \
            "Command '$1' not found"
    fi
}

################################################################################
# Audit Functions
################################################################################

audit_system_identity() {
    print_header "SYSTEM IDENTITY"
    
    run_command "Hostname" hostname
    run_command "Operating System" cat /etc/os-release
    run_command "Kernel Version" uname -r
    run_command "System Uptime" uptime -p
    run_command "Current Date/Time" date
    run_shell_command "Timezone" 'timedatectl 2>/dev/null || date +%Z'
}

audit_network() {
    print_header "NETWORK CONFIGURATION"
    
    run_command "Network Interfaces" ip -br addr
    run_command "Routing Table" ip route
    run_command "DNS Configuration" cat /etc/resolv.conf
    safe_run "Active Connections" ss -tuln
    safe_run "Listening Services" ss -tlnp
    run_command "Hosts File" cat /etc/hosts
}

audit_users() {
    print_header "USER ACCOUNTS"
    
    run_command "All User Accounts" cat /etc/passwd
    run_command "User Groups" cat /etc/group
    run_shell_command "Sudo Configuration" 'cat /etc/sudoers 2>/dev/null || echo "Access denied to /etc/sudoers"'
    safe_run "Currently Logged In Users" w
    safe_run "Last Logins" last -n 20
    run_shell_command "Failed Login Attempts" 'lastb -n 20 2>/dev/null || echo "No failed login records or access denied"'
}

audit_ssh() {
    print_header "SSH CONFIGURATION"
    
    if [ -f /etc/ssh/sshd_config ]; then
        run_shell_command "SSH Server Config" 'grep -v "^#" /etc/ssh/sshd_config | grep -v "^$"'
    else
        echo "SSH config not found" | tee -a "$LOG_FILE"
    fi
    
    run_shell_command "SSH Service Status" 'systemctl status ssh 2>/dev/null || systemctl status sshd 2>/dev/null || echo "SSH service not found"'
    
    if [ -d ~/.ssh ]; then
        run_shell_command "Authorized Keys" 'cat ~/.ssh/authorized_keys 2>/dev/null || echo "No authorized_keys file"'
    fi
}

audit_firewall() {
    print_header "FIREWALL & SECURITY"
    
    # Check for UFW
    if command -v ufw &> /dev/null; then
        safe_run "UFW Status" ufw status verbose
    fi
    
    # Check for iptables
    if command -v iptables &> /dev/null; then
        safe_run "iptables Rules" iptables -L -n -v
    fi
    
    # Check SELinux
    if command -v getenforce &> /dev/null; then
        safe_run "SELinux Status" getenforce
    fi
    
    # Check AppArmor
    if command -v aa-status &> /dev/null; then
        safe_run "AppArmor Status" aa-status
    fi
}

audit_packages() {
    print_header "INSTALLED PACKAGES"
    
    # Debian/Ubuntu
    if command -v dpkg &> /dev/null; then
        run_command "Installed Packages (dpkg)" dpkg -l
    fi
    
    # RedHat/CentOS
    if command -v rpm &> /dev/null; then
        safe_run "Installed Packages (rpm)" rpm -qa
    fi
    
    # Package managers
    if command -v apt &> /dev/null; then
        run_shell_command "APT Update Status" 'apt list --upgradable 2>/dev/null || echo "No upgradable packages"'
    fi
    
    if command -v yum &> /dev/null; then
        run_shell_command "YUM Update Status" 'yum check-update || echo "No updates available"'
    fi
}

audit_resources() {
    print_header "DISK & MEMORY USAGE"
    
    run_command "Disk Usage" df -h
    run_command "Disk Inodes" df -i
    run_command "Memory Usage" free -h
    safe_run "Swap Usage" swapon --show
    run_command "Block Devices" lsblk
}

audit_services() {
    print_header "RUNNING SERVICES"
    
    safe_run "Systemd Services" systemctl list-units --type=service --state=running
    safe_run "All Systemd Services" systemctl list-unit-files --type=service
    run_shell_command "Running Processes" 'ps aux --sort=-%mem | head -20'
    run_shell_command "Cron Jobs (Root)" 'crontab -l 2>/dev/null || echo "No cron jobs for root"'
    
    if [ -d /etc/cron.d ]; then
        run_command "System Cron Jobs" ls -la /etc/cron.d/
    fi
}

audit_logs() {
    print_header "RECENT ERRORS & LOGS"
    
    if [ -f /var/log/syslog ]; then
        run_shell_command "Recent Syslog Errors" 'grep -i error /var/log/syslog | tail -20 || echo "No recent errors"'
    elif [ -f /var/log/messages ]; then
        run_shell_command "Recent Message Log Errors" 'grep -i error /var/log/messages | tail -20 || echo "No recent errors"'
    fi
    
    run_shell_command "Systemd Journal Errors" 'journalctl -p err -n 20 --no-pager 2>/dev/null || echo "Journal not accessible"'
    run_shell_command "Authentication Logs" 'tail -20 /var/log/auth.log 2>/dev/null || tail -20 /var/log/secure 2>/dev/null || echo "Auth logs not accessible"'
}

################################################################################
# Main Execution
################################################################################

main() {
    local generated_at_utc
    local hostname_value
    local run_mode

    generated_at_utc="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    hostname_value="$(hostname 2>/dev/null || echo unknown)"
    if [ "$EUID" -eq 0 ]; then
        run_mode="root"
    else
        run_mode="non-root"
    fi

    {
        echo "SignalForge Linux Audit Report"
        echo "Generated at (UTC): ${generated_at_utc}"
        echo "Collector: first-audit.sh"
        echo "Hostname: ${hostname_value}"
        echo "Run mode: ${run_mode}"
        echo "Log file: ${LOG_FILE}"
    } > "$LOG_FILE"

    echo "SignalForge Linux Audit"
    echo "Generated at (UTC): ${generated_at_utc}"
    echo "Collector: first-audit.sh"
    echo "Hostname: ${hostname_value}"
    echo "Run mode: ${run_mode}"
    echo ""
    
    # Run all audit sections
    audit_system_identity
    audit_network
    audit_users
    audit_ssh
    audit_firewall
    audit_packages
    audit_resources
    audit_services
    audit_logs
    
    # Summary
    echo ""
    if [ "$IS_TTY" -eq 1 ]; then
        terminal_line "${BOLD}${GREEN}Audit complete.${NC}"
        terminal_line "Full report saved to: ${BOLD}${BLUE}${LOG_FILE}${NC}"
    else
        echo "Audit complete."
        echo "Full report saved to: ${LOG_FILE}"
    fi
    echo ""
    
    # Add footer to log
    {
        echo ""
        echo "$SECTION_DIVIDER"
        echo "Audit completed at: $(date)"
        echo "$SECTION_DIVIDER"
    } >> "$LOG_FILE"
}

# Check if running with sudo/root for complete audit
if [ "$EUID" -ne 0 ]; then
    if [ "$IS_TTY" -eq 1 ]; then
        terminal_line "${YELLOW}Warning: not running as root. Some information may be limited.${NC}"
        terminal_line "${YELLOW}Consider running with: sudo ./first-audit.sh${NC}"
    else
        echo "Warning: not running as root. Some information may be limited."
        echo "Consider running with: sudo ./first-audit.sh"
    fi
    echo ""
fi

main

exit 0
