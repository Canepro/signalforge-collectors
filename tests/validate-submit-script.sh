#!/usr/bin/env bash
# Lightweight checks for submit-to-signalforge.sh (no live HTTP).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash -n submit-to-signalforge.sh

out="$(./submit-to-signalforge.sh --help)"
echo "$out" | grep -q "SignalForge"

grep -q 'target_identifier' submit-to-signalforge.sh
grep -q 'source_label' submit-to-signalforge.sh
grep -q 'collector_type' submit-to-signalforge.sh
grep -q 'collector_version' submit-to-signalforge.sh
grep -q 'collected_at' submit-to-signalforge.sh
grep -q 'source_type=api' submit-to-signalforge.sh
grep -q 'artifact_type' submit-to-signalforge.sh

echo "validate-submit-script: ok"
