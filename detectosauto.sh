#!/bin/bash

# Function to detect Oracle database service management method
# Returns:
# management_system: systemd, initd, initd_via_systemd, or unknown
# service_name: The service name or script name
detect_oracle_service() {
    local management_system="unknown"
    local service_name=""
    local systemd_unit=""

    # Check if a service name was provided as argument
    local provided_service="$1"

    if [ -n "$provided_service" ]; then
        # User provided a service name, check if it exists in systemd
        if systemctl list-unit-files "$provided_service"* &>/dev/null; then
            # Get the systemd unit name
            systemd_unit="$provided_service"

            # Check if this systemd service is wrapping an init.d script
            local status_output=$(systemctl status "$provided_service" 2>/dev/null)

            # Check if the systemd unit is loaded from an init.d script
            if echo "$status_output" | grep -q -E "Loaded: loaded \(/etc/(rc\.d/)?init\.d/"; then
                local initd_script=$(echo "$status_output" |
                                  grep -E "Loaded: loaded \(/etc/(rc\.d/)?init\.d/" |
                                  sed -E 's/.*Loaded: loaded \(\/etc\/(rc\.d\/)?init\.d\/([^;]+).*/\3/')

                management_system="initd_via_systemd"
                service_name="$initd_script"
            else
                management_system="systemd"
                service_name="$provided_service"
            fi
        elif [ -f "/etc/init.d/$provided_service" ]; then
            management_system="initd"
            service_name="$provided_service"
        else
            # Service not found with the provided name
            return 1
        fi
    else
        # Auto-detect based on running Oracle processes
        local ORA_PID=$(pgrep -f ora_pmon | head -1)

        if [ -z "$ORA_PID" ]; then
            # No Oracle processes found
            return 1
        fi

        # Check if process is managed by systemd
        if systemctl status "$ORA_PID" &>/dev/null; then
            # Get systemd unit name - first try the standard method
            local status_output=$(systemctl status "$ORA_PID" --no-pager 2>/dev/null)
            systemd_unit=$(echo "$status_output" | grep -o '[^ ]*\.service' | head -1 | tr -d '[:cntrl:]')

            # If no unit name found, try alternative method to get the unit name
            if [ -z "$systemd_unit" ]; then
                systemd_unit=$(systemctl status "$ORA_PID" --no-pager 2>/dev/null |
                            grep -E '^[[:space:]]*●' | sed -E 's/^[[:space:]]*●[[:space:]]+([^[:space:]]+).*/\1/')
            fi

            # Check if this systemd service is wrapping an init.d script by looking at the Loaded: line
            if echo "$status_output" | grep -q -E "Loaded: loaded \(/etc/(rc\.d/)?init\.d/"; then
                local initd_script=$(echo "$status_output" |
                                  grep -E "Loaded: loaded \(/etc/(rc\.d/)?init\.d/" |
                                  sed -E 's/.*Loaded: loaded \(\/etc\/(rc\.d\/)?init\.d\/([^;]+).*/\3/')

                management_system="initd_via_systemd"
                service_name="$initd_script"
            else
                management_system="systemd"
                service_name="$systemd_unit"
            fi
        else
            # Check if managed by init.d
            local ppid=$(ps -o ppid= -p "$ORA_PID" | tr -d ' ')

            # Trace parent process to see if it leads to an init script
            while [ "$ppid" != "1" ] && [ -n "$ppid" ]; do
                local cmd=$(ps -o cmd= -p "$ppid" 2>/dev/null)
                if [[ "$cmd" == *"/etc/init.d/"* ]]; then
                    management_system="initd"
                    service_name=$(echo "$cmd" | grep -o '/etc/init.d/[^ ]*' | sed 's/.*\/etc\/init.d\///')
                    break
                fi
                ppid=$(ps -o ppid= -p "$ppid" 2>/dev/null | tr -d ' ')
                # Safety check to avoid infinite loops
                if [ -z "$ppid" ]; then
                    break
                fi
            done

            # If still not found, check if any init.d scripts are running
            if [ "$management_system" = "unknown" ]; then
                # Look for common Oracle init script names
                for script in $(find /etc/init.d -type f | grep -i ora); do
                    if [ -x "$script" ]; then
                        # Check if this script is related to the running process
                        script_name=$(basename "$script")
                        if ps -ef | grep -v grep | grep -q "$script_name"; then
                            management_system="initd"
                            service_name="$script_name"
                            break
                        fi
                    fi
                done
            fi
        fi
    fi

    # Return results based on the management system
    case "$management_system" in
        "systemd")
            echo "systemd" "$service_name"
            return 0
            ;;
        "initd")
            echo "initd" "$service_name"
            return 0
            ;;
        "initd_via_systemd")
            echo "initd_via_systemd" "$service_name" "$systemd_unit"
            return 0
            ;;
        *)
            echo "unknown" ""
            return 1
            ;;
    esac
}


# Example usage:
#
# Auto-detect:
# result=($(detect_oracle_service))
# management_system=${result[0]}
# service_name=${result[1]}
# systemd_unit=${result[2]}  # Only if management_system is "initd_via_systemd"
#
# Or with a provided service name:
# result=($(detect_oracle_service "oracle"))
# management_system=${result[0]}
# service_name=${result[1]}
# systemd_unit=${result[2]}  # Only if management_system is "initd_via_systemd"
#
# if [ "$management_system" = "unknown" ]; then
#     echo "Could not detect Oracle service"
#     exit 1
# fi
#
# echo "Management system: $management_system"
# echo "Service name: $service_name"
# if [ "$management_system" = "initd_via_systemd" ]; then
#     echo "Systemd unit: $systemd_unit"
# fi


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