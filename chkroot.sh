#!/bin/bash

CHECKSUM_FILE="/etc/oracle_rootsh_checksums"

# Validate input
if [[ -z "$1" ]]; then
    echo "Usage: sudo $0 /full/path/to/root.sh"
    exit 1
fi

ROOT_SCRIPT="$1"

# Ensure the file exists and is readable
if [[ ! -f "$ROOT_SCRIPT" ]] || [[ ! -r "$ROOT_SCRIPT" ]]; then
    echo "Error: Specified root.sh file does not exist or is not readable."
    exit 1
fi

# Calculate the script's checksum
script_checksum=$(sha256sum "$ROOT_SCRIPT" | awk '{print $1}')

# Check if the checksum is in the approved list
if grep -Fxq "$script_checksum" "$CHECKSUM_FILE"; then
    echo "Checksum validation passed. Executing: $ROOT_SCRIPT"
    /bin/bash "$ROOT_SCRIPT"
    exit $?
else
    echo "Error: Checksum validation failed. Unauthorized root.sh."
    exit 1
fi