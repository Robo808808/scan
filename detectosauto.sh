#!/bin/bash

# Function to detect Oracle database service management method
# Returns two values:
# 1. Management system (systemd, initd, or unknown)
# 2. Service unit name (or empty if unknown)
detect_oracle_service() {
    local management_type=""
    local service_name=""

    # Find Oracle PMON processes
    local ORA_PIDS=$(pgrep -f ora_pmon)

    if [ -z "$ORA_PIDS" ]; then
        echo "unknown" ""
        return 1
    fi

    # Take the first PMON process found (usually one per database instance)
    local pid=$(echo "$ORA_PIDS" | head -1)

    # Check if process is managed by systemd
    if systemctl status $pid &>/dev/null; then
        management_type="systemd"
        service_name=$(systemctl status $pid --no-pager | grep -o '[^ ]*\.service' | head -1)
        # Remove any potential control characters
        service_name=$(echo "$service_name" | tr -d '[:cntrl:]')
    else
        # Check if managed by init.d
        local ppid=$(ps -o ppid= -p $pid | tr -d ' ')

        # Trace parent process to see if it leads to an init script
        while [ "$ppid" != "1" ] && [ -n "$ppid" ]; do
            local cmd=$(ps -o cmd= -p $ppid 2>/dev/null)
            if [[ "$cmd" == *"/etc/init.d/"* ]]; then
                management_type="initd"
                service_name=$(echo "$cmd" | grep -o '/etc/init.d/[^ ]*' | sed 's/.*\/etc\/init.d\///')
                break
            fi
            ppid=$(ps -o ppid= -p $ppid 2>/dev/null | tr -d ' ')
            # Safety check to avoid infinite loops
            if [ -z "$ppid" ]; then
                break
            fi
        done

        # If still not found, check if any init.d scripts are running
        if [ -z "$management_type" ]; then
            # Look for common Oracle init script names
            for script in $(find /etc/init.d -type f | grep -i ora); do
                if [ -x "$script" ]; then
                    # Check if this script is related to the running process
                    script_name=$(basename "$script")
                    if ps -ef | grep -v grep | grep -q "$script_name"; then
                        management_type="initd"
                        service_name="$script_name"
                        break
                    fi
                fi
            done
        fi
    fi

    # If still not determined, mark as unknown
    if [ -z "$management_type" ]; then
        management_type="unknown"
    fi

    # Return results
    echo "$management_type" "$service_name"
}

# Function to check if a service is managed by systemd
is_systemd_service() {
    local service_name="$1"
    if systemctl list-unit-files | grep -q "$service_name"; then
        return 0  # True
    else
        return 1  # False
    fi
}

# Function to check if a service is managed by init.d
is_initd_service() {
    local service_name="$1"
    if [ -f "/etc/init.d/$service_name" ]; then
        return 0  # True
    else
        return 1  # False
    fi
}

# Function to check if chkconfig is available and manages a service
is_chkconfig_managed() {
    local service_name="$1"
    if command -v chkconfig >/dev/null && chkconfig --list "$service_name" &>/dev/null; then
        return 0  # True
    else
        return 1  # False
    fi
}

# Function to backup and remove systemd service
backup_remove_systemd() {
    local service_name="$1"
    echo "Backing up and removing systemd service: $service_name"

    # Find service file location
    local service_path=$(systemctl show "$service_name" -p FragmentPath | cut -d= -f2)

    if [ -z "$service_path" ] || [ ! -f "$service_path" ]; then
        echo "Error: Cannot find systemd service file for $service_name"
        return 1
    fi

    # Create backup with date suffix
    local backup_path="${service_path}.backup-$(date +%Y%m%d-%H%M%S)"
    echo "Creating backup of service file: $backup_path"
    cp "$service_path" "$backup_path"

    # Stop and disable the service
    echo "Stopping and disabling service"
    systemctl stop "$service_name"
    systemctl disable "$service_name"

    # Remove the service file
    echo "Removing service file"
    rm -f "$service_path"

    # Reload systemd
    echo "Reloading systemd daemon"
    systemctl daemon-reload

    echo "Successfully removed systemd service: $service_name"
    return 0
}

# Function to backup and remove init.d service
backup_remove_initd() {
    local service_name="$1"
    echo "Backing up and removing init.d service: $service_name"

    local initd_path="/etc/init.d/$service_name"

    if [ ! -f "$initd_path" ]; then
        echo "Error: Cannot find init.d script for $service_name"
        return 1
    fi

    # Create backup with date suffix
    local backup_path="${initd_path}.backup-$(date +%Y%m%d-%H%M%S)"
    echo "Creating backup of init script: $backup_path"
    cp "$initd_path" "$backup_path"

    # Stop the service
    echo "Stopping service"
    "$initd_path" stop

    # If chkconfig is available, use it to remove the service
    if is_chkconfig_managed "$service_name"; then
        echo "Service is managed by chkconfig, removing service registration"
        chkconfig --del "$service_name"
    fi

    # Remove symbolic links in runlevel directories
    echo "Removing runlevel symlinks"
    find /etc/rc*.d/ -name "[SK][0-9][0-9]$service_name" -delete

    # Remove the init script
    echo "Removing init script"
    rm -f "$initd_path"

    echo "Successfully removed init.d service: $service_name"
    return 0
}

# Main script function
main() {
    local service_name=""
    local management_type=""

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)
                service_name="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                echo "Usage: $0 [--service SERVICE_NAME]"
                exit 1
                ;;
        esac
    done

    # If service name is provided, determine its type
    if [ -n "$service_name" ]; then
        echo "Service name provided: $service_name"

        if is_systemd_service "$service_name"; then
            management_type="systemd"
        elif is_initd_service "$service_name"; then
            management_type="initd"
        else
            echo "Error: Cannot determine management type for service '$service_name'"
            echo "Service not found in systemd or init.d"
            exit 1
        fi
    else
        # Auto-detect the service
        echo "Detecting Oracle service..."
        result=($(detect_oracle_service))
        management_type=${result[0]}
        service_name=${result[1]}

        # Exit if detection failed
        if [ "$management_type" = "unknown" ]; then
            echo "Error: Unable to detect Oracle service management method"
            exit 1
        fi

        if [ -z "$service_name" ]; then
            echo "Error: Unable to determine service name"
            exit 1
        fi
    fi

    echo "Management system: $management_type"
    echo "Service name: $service_name"

    # Backup and remove the service based on its type
    if [ "$management_type" = "systemd" ]; then
        backup_remove_systemd "$service_name"
    elif [ "$management_type" = "initd" ]; then
        backup_remove_initd "$service_name"
    else
        echo "Error: Unknown management type '$management_type'"
        exit 1
    fi
}

# Run the main function with all arguments
main "$@"