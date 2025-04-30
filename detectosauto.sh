#!/bin/bash
# Find Oracle PMON processes
ORA_PIDS=$(pgrep -f ora_pmon)

if [ -z "$ORA_PIDS" ]; then
    echo "No Oracle PMON processes found."
    exit 1
fi

for pid in $ORA_PIDS; do
    echo "============================================"
    echo "Oracle PMON process: $pid"

    # Check if process is managed by systemd
    if systemctl status $pid &>/dev/null; then
        echo "✓ Managed by systemd"
        echo "Service unit: $(systemctl status $pid --no-pager | grep -o '.*\.service' | head -1)"
        systemctl status $pid --no-pager | head -5
    else
        # Check if managed by init.d
        ppid=$(ps -o ppid= -p $pid | tr -d ' ')
        init_script=""

        # Trace parent process to see if it leads to an init script
        while [ "$ppid" != "1" ] && [ -n "$ppid" ]; do
            cmd=$(ps -o cmd= -p $ppid | grep -o "[^ ]*$" | head -1)
            if [[ "$cmd" == *"/etc/init.d/"* ]]; then
                init_script=$(echo "$cmd" | sed 's/.*\/etc\/init.d\///')
                break
            fi
            ppid=$(ps -o ppid= -p $ppid | tr -d ' ')
        done

        if [ -n "$init_script" ]; then
            echo "✓ Managed by init.d"
            echo "Init script: $init_script"
        else
            echo "? Not clearly managed by systemd or init.d"
            echo "Process tree:"
            pstree -s -p $pid
        fi
    fi
done