#!/bin/bash

################################################################################
# Audit Diff Script
# Purpose: Compare two audit logs to identify changes in system configuration
# Usage: ./diff-audit.sh <baseline_log> <current_log>
################################################################################

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

################################################################################
# Helper Functions
################################################################################

print_usage() {
    cat << EOF
Usage: $0 <baseline_log> <current_log>

Compare two server audit logs to identify changes.

Arguments:
    baseline_log    Earlier audit log file (reference point)
    current_log     Later audit log file (to compare against baseline)

Example:
    $0 server_audit_20250101_120000.log server_audit_20250102_120000.log

EOF
    exit 1
}

print_section_header() {
    local title="$1"
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${YELLOW}$title${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

extract_section() {
    local file="$1"
    local section="$2"
    local start_pattern="\\[$section\\]"
    local end_pattern="^━━━"
    
    awk "/$start_pattern/,/$end_pattern/ {print}" "$file" | grep -v "^━━━" | grep -v "\\[$section\\]" || true
}

compare_section() {
    local section_name="$1"
    local baseline="$2"
    local current="$3"
    
    local baseline_section
    local current_section
    baseline_section=$(mktemp)
    current_section=$(mktemp)
    
    extract_section "$baseline" "$section_name" > "$baseline_section"
    extract_section "$current" "$section_name" > "$current_section"
    
    if ! diff -u "$baseline_section" "$current_section" > /dev/null 2>&1; then
        print_section_header "CHANGES IN: $section_name"
        
        echo -e "${GREEN}+ = Added/New${NC}"
        echo -e "${RED}- = Removed/Old${NC}"
        echo ""
        
        diff -u "$baseline_section" "$current_section" | tail -n +3 | while IFS= read -r line; do
            if [[ "$line" == +* ]] && [[ "$line" != "+++"* ]]; then
                echo -e "${GREEN}$line${NC}"
            elif [[ "$line" == -* ]] && [[ "$line" != "---"* ]]; then
                echo -e "${RED}$line${NC}"
            else
                echo "$line"
            fi
        done
    fi
    
    rm -f "$baseline_section" "$current_section"
}

analyze_user_changes() {
    local baseline="$1"
    local current="$2"
    
    local baseline_users
    local current_users
    baseline_users=$(mktemp)
    current_users=$(mktemp)
    
    extract_section "$baseline" "USER ACCOUNTS" | grep -E "^[^:]+:[^:]+:[0-9]+:" | cut -d: -f1 | sort > "$baseline_users" || true
    extract_section "$current" "USER ACCOUNTS" | grep -E "^[^:]+:[^:]+:[0-9]+:" | cut -d: -f1 | sort > "$current_users" || true
    
    local new_users
    local removed_users
    new_users=$(comm -13 "$baseline_users" "$current_users")
    removed_users=$(comm -23 "$baseline_users" "$current_users")
    
    if [ -n "$new_users" ] || [ -n "$removed_users" ]; then
        print_section_header "USER ACCOUNT CHANGES"
        
        if [ -n "$new_users" ]; then
            echo -e "${GREEN}${BOLD}New Users:${NC}"
            echo "$new_users" | while read -r user; do
                echo -e "${GREEN}  + $user${NC}"
            done
            echo ""
        fi
        
        if [ -n "$removed_users" ]; then
            echo -e "${RED}${BOLD}Removed Users:${NC}"
            echo "$removed_users" | while read -r user; do
                echo -e "${RED}  - $user${NC}"
            done
            echo ""
        fi
    fi
    
    rm -f "$baseline_users" "$current_users"
}

analyze_package_changes() {
    local baseline="$1"
    local current="$2"
    
    local baseline_pkgs
    local current_pkgs
    baseline_pkgs=$(mktemp)
    current_pkgs=$(mktemp)
    
    # Extract package names (works for both dpkg and rpm formats)
    extract_section "$baseline" "INSTALLED PACKAGES" | grep -E "^(ii|[a-zA-Z0-9])" | awk '{print $2}' | sort | uniq > "$baseline_pkgs" || true
    extract_section "$current" "INSTALLED PACKAGES" | grep -E "^(ii|[a-zA-Z0-9])" | awk '{print $2}' | sort | uniq > "$current_pkgs" || true
    
    local new_packages
    local removed_packages
    new_packages=$(comm -13 "$baseline_pkgs" "$current_pkgs" | head -20)
    removed_packages=$(comm -23 "$baseline_pkgs" "$current_pkgs" | head -20)
    
    if [ -n "$new_packages" ] || [ -n "$removed_packages" ]; then
        print_section_header "PACKAGE CHANGES"
        
        if [ -n "$new_packages" ]; then
            echo -e "${GREEN}${BOLD}New Packages (showing first 20):${NC}"
            echo "$new_packages" | while read -r pkg; do
                echo -e "${GREEN}  + $pkg${NC}"
            done
            echo ""
        fi
        
        if [ -n "$removed_packages" ]; then
            echo -e "${RED}${BOLD}Removed Packages (showing first 20):${NC}"
            echo "$removed_packages" | while read -r pkg; do
                echo -e "${RED}  - $pkg${NC}"
            done
            echo ""
        fi
    fi
    
    rm -f "$baseline_pkgs" "$current_pkgs"
}

analyze_disk_changes() {
    local baseline="$1"
    local current="$2"
    
    print_section_header "DISK USAGE COMPARISON"
    
    local baseline_disk
    local current_disk
    baseline_disk=$(mktemp)
    current_disk=$(mktemp)
    
    extract_section "$baseline" "DISK & MEMORY USAGE" | grep -A 20 "Disk Usage" | grep "^/" > "$baseline_disk" || true
    extract_section "$current" "DISK & MEMORY USAGE" | grep -A 20 "Disk Usage" | grep "^/" > "$current_disk" || true
    
    if [ -s "$baseline_disk" ] && [ -s "$current_disk" ]; then
        echo -e "${BOLD}Filesystem Usage Changes:${NC}\n"
        printf "%-20s %10s %10s %10s\n" "Filesystem" "Baseline" "Current" "Change"
        echo "───────────────────────────────────────────────────────"
        
        while IFS= read -r baseline_line; do
            local fs
            local baseline_usage
            local current_line
            fs=$(echo "$baseline_line" | awk '{print $1}')
            baseline_usage=$(echo "$baseline_line" | awk '{print $5}' | tr -d '%')
            current_line=$(grep "^$fs " "$current_disk" || true)
            
            if [ -n "$current_line" ]; then
                local current_usage
                current_usage=$(echo "$current_line" | awk '{print $5}' | tr -d '%')
                local change=$((current_usage - baseline_usage))
                
                if [ "$change" -gt 5 ]; then
                    echo -e "$(printf '%-20s %9s%% %9s%%' "$fs" "$baseline_usage" "$current_usage") ${RED}+${change}%${NC}"
                elif [ "$change" -lt -5 ]; then
                    echo -e "$(printf '%-20s %9s%% %9s%%' "$fs" "$baseline_usage" "$current_usage") ${GREEN}${change}%${NC}"
                else
                    printf '%-20s %9s%% %9s%% %9s%%\n' "$fs" "$baseline_usage" "$current_usage" "$change"
                fi
            fi
        done < "$baseline_disk"
        echo ""
    else
        echo "Unable to extract disk usage information from logs."
    fi
    
    rm -f "$baseline_disk" "$current_disk"
}

analyze_service_changes() {
    local baseline="$1"
    local current="$2"
    
    local baseline_services
    local current_services
    baseline_services=$(mktemp)
    current_services=$(mktemp)
    
    extract_section "$baseline" "RUNNING SERVICES" | grep "\.service" | awk '{print $1}' | sort | uniq > "$baseline_services" || true
    extract_section "$current" "RUNNING SERVICES" | grep "\.service" | awk '{print $1}' | sort | uniq > "$current_services" || true
    
    local new_services
    local stopped_services
    new_services=$(comm -13 "$baseline_services" "$current_services")
    stopped_services=$(comm -23 "$baseline_services" "$current_services")
    
    if [ -n "$new_services" ] || [ -n "$stopped_services" ]; then
        print_section_header "SERVICE CHANGES"
        
        if [ -n "$new_services" ]; then
            echo -e "${GREEN}${BOLD}New/Started Services:${NC}"
            echo "$new_services" | while read -r svc; do
                echo -e "${GREEN}  + $svc${NC}"
            done
            echo ""
        fi
        
        if [ -n "$stopped_services" ]; then
            echo -e "${RED}${BOLD}Stopped/Removed Services:${NC}"
            echo "$stopped_services" | while read -r svc; do
                echo -e "${RED}  - $svc${NC}"
            done
            echo ""
        fi
    fi
    
    rm -f "$baseline_services" "$current_services"
}

################################################################################
# Main Execution
################################################################################

main() {
    # Print banner
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║           SERVER AUDIT DIFFERENTIAL ANALYSIS                   ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${BOLD}Baseline:${NC} $BASELINE_LOG"
    echo -e "${BOLD}Current:${NC}  $CURRENT_LOG"
    
    # Perform detailed comparisons
    analyze_user_changes "$BASELINE_LOG" "$CURRENT_LOG"
    analyze_service_changes "$BASELINE_LOG" "$CURRENT_LOG"
    analyze_package_changes "$BASELINE_LOG" "$CURRENT_LOG"
    analyze_disk_changes "$BASELINE_LOG" "$CURRENT_LOG"
    
    # Compare other important sections
    compare_section "NETWORK CONFIGURATION" "$BASELINE_LOG" "$CURRENT_LOG"
    compare_section "SSH CONFIGURATION" "$BASELINE_LOG" "$CURRENT_LOG"
    compare_section "FIREWALL & SECURITY" "$BASELINE_LOG" "$CURRENT_LOG"
    
    # Summary
    echo ""
    echo -e "${BOLD}${GREEN}✓ Comparison complete!${NC}"
    echo ""
}

# Validate arguments
if [ $# -ne 2 ]; then
    print_usage
fi

readonly BASELINE_LOG="$1"
readonly CURRENT_LOG="$2"

# Check if files exist
if [ ! -f "$BASELINE_LOG" ]; then
    echo -e "${RED}Error: Baseline log file not found: $BASELINE_LOG${NC}"
    exit 1
fi

if [ ! -f "$CURRENT_LOG" ]; then
    echo -e "${RED}Error: Current log file not found: $CURRENT_LOG${NC}"
    exit 1
fi

main

exit 0
