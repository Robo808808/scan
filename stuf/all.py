import psutil
import json
import subprocess
import re


def scan_listening_ports():
    """Scan all listening ports and return details for processes named 'tnslsnr' with exactly three cmdline arguments."""
    listening_ports = []
    for conn in psutil.net_connections(kind='inet'):
        if conn.status == psutil.CONN_LISTEN:
            pid = conn.pid
            if pid:
                try:
                    process = psutil.Process(pid)
                    if process.name().lower() == "tnslsnr":
                        cmdline = process.cmdline()
                        if len(cmdline) == 3:  # Only process if cmdline has exactly three parts
                            second_arg = cmdline[1]
                            listening_ports.append({
                                "port": conn.laddr.port,
                                "process_name": process.name(),
                                "pid": pid,
                                "cmdline_second_arg": second_arg
                            })
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue
    return listening_ports


def run_lsnrctl_status_and_parse(processes):
    """Run 'lsnrctl status <cmdline_second_arg>' for each process and return consolidated details."""
    consolidated_info = []

    for process in processes:
        cmdline_arg = process.get("cmdline_second_arg")
        if cmdline_arg:
            try:
                print(f"Running command: lsnrctl status {cmdline_arg}")
                result = subprocess.run(["lsnrctl", "status", cmdline_arg], capture_output=True, text=True)
                output = result.stdout

                # Find all services listed under "Instance"
                services = re.findall(r'Instance\s+"(.+?)"', output)
                consolidated_info.append({
                    "port": process["port"],
                    "cmdline_second_arg": cmdline_arg,
                    "services": services
                })

            except Exception as e:
                print(f"Failed to run 'lsnrctl status {cmdline_arg}': {e}")
                consolidated_info.append({
                    "port": process["port"],
                    "cmdline_second_arg": cmdline_arg,
                    "services": []
                })

    return consolidated_info


def get_consolidated_info():
    """Consolidate the results from both scanning and running the lsnrctl status."""
    # Step 1: Scan listening ports
    processes = scan_listening_ports()

    # Step 2: Run lsnrctl status for each process and parse the services
    consolidated_info = run_lsnrctl_status_and_parse(processes)

    return consolidated_info


# Example usage
consolidated_results = get_consolidated_info()

# Print the JSON results
print(json.dumps(consolidated_results, indent=4))
