import nmap

def scan_ports_for_oracle(host, port_range):
    """
    Scan a remote host for listening ports within a specified range and check for Oracle listener.

    Args:
        host (str): IP or hostname of the target server.
        port_range (str): Port range to scan (e.g., "1521-1530").

    Returns:
        dict: Dictionary of open ports with their service details.
    """
    scanner = nmap.PortScanner()

    try:
        # Run the Nmap scan
        print(f"Scanning {host} for open ports in range {port_range}...")
        scanner.scan(hosts=host, ports=port_range, arguments='-sV')  # -sV: Service/version detection

        open_ports = {}
        for host in scanner.all_hosts():
            for proto in scanner[host].all_protocols():
                ports = scanner[host][proto]
                for port, details in ports.items():
                    if details['state'] == 'open':
                        open_ports[port] = details

        return open_ports

    except Exception as e:
        print(f"Error scanning ports: {e}")
        return {}


def find_oracle_listener(host, port_range):
    """
    Identify if an Oracle listener is running on any open ports.

    Args:
        host (str): IP or hostname of the target server.
        port_range (str): Port range to scan (e.g., "1521-1530").

    Returns:
        int: Port number where Oracle listener is detected, or None if not found.
    """
    open_ports = scan_ports_for_oracle(host, port_range)
    for port, details in open_ports.items():
        service_name = details.get('name', '').lower()
        if 'oracle' in service_name:
            print(f"Oracle listener detected on port {port}: {details}")
            return port
    print("No Oracle listener detected in the specified port range.")
    return None


if __name__ == "__main__":
    # User-defined input
    target_host = input("Enter the target server (IP or hostname): ")
    port_range = input("Enter the port range to scan (e.g., 1521-1530): ")

    oracle_port = find_oracle_listener(target_host, port_range)
    if oracle_port:
        print(f"Oracle listener is running on port {oracle_port}.")
    else:
        print("Oracle listener not found.")
