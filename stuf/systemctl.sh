#!/bin/bash

ISSUES=""

output=$(systemctl status dbora 2>&1 | grep "Loaded:")

if echo "$output" | grep -q "systemd"; then
  echo "dbora is a systemd-managed service"
elif echo "$output" | grep -q "init.d"; then
  echo "dbora is an init.d-style service"
elif echo "$output" | grep -q "could not be found"; then
  echo "dbora service not found"
  ISSUES+="dbora service not found\n"
else
  echo "Unexpected status: $output"
  ISSUES+="Unexpected systemctl output: $output\n"
fi

# Optional final summary
if [[ -n "$ISSUES" ]]; then
  echo -e "\nSummary of Issues:"
  echo -e "$ISSUES"
  exit 1
else
  echo "Service check passed."
  exit 0
fi

# Output block
echo "=== START REPORT FOR $HOST ==="
if (( ${#ISSUES[@]} > 0 )); then
  for issue in "${ISSUES[@]}"; do
    echo "ISSUE: $issue"
  done
else
  echo "OK: Service check passed"
fi
echo "=== END REPORT FOR $HOST ==="




#!/bin/bash

# BladeLogic-compatible Oracle startup validation script
# Outputs START/END blocks and issue details for parsing later

HOST=$(hostname)
ISSUES=()

# --- Check 1: start.sh script presence ---
if [[ ! -f /home/oracle/scripts/start.sh ]]; then
  ISSUES+=("Missing start.sh script")
fi

# --- Check 2: dbora service status ---
output=$(systemctl status dbora 2>&1 | grep "Loaded:")
if echo "$output" | grep -q "could not be found"; then
  ISSUES+=("dbora service not found")
elif ! echo "$output" | grep -Eq "systemd|init.d"; then
  ISSUES+=("Unexpected dbora service state: $output")
fi

# --- Output Results in BladeLogic-friendly format ---
echo "=== START REPORT FOR $HOST ==="

if (( ${#ISSUES[@]} > 0 )); then
  for issue in "${ISSUES[@]}"; do
    echo "ISSUE: $issue"
  done
else
  echo "OK: Service check passed"
fi

echo "=== END REPORT FOR $HOST ==="
