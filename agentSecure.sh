#!/bin/bash

# Find the PID of the process matching "agent_13" and "java"
PID=$(ps aux | grep "agent_13" | grep "java" | grep -v grep | awk '{print $2}')

# Check if a PID was found
if [[ -z "$PID" ]]; then
    echo "No matching process found."
    exit 1
fi

# Get the working directory of the process
CWD_PATH="/proc/$PID/cwd"

# Resolve and print the working directory
if [[ -L "$CWD_PATH" ]]; then
    FULL_CWD=$(readlink -f "$CWD_PATH")
    # Extract the base path up to and including "agent_inst" or "agent_13.x.x.x.x"
    BASE_CWD=$(echo "$FULL_CWD" | grep -oP ".*/agent_(inst|13\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)")
    echo "Base working directory for PID $PID: $BASE_CWD"
else
    echo "Unable to determine working directory."
fi
