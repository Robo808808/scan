import python-nmap

def scan_ports_with_tls_detection(host, port_range):
    """
    Scan a remote host for listening ports within a specified range and check for encrypted (TCPS) services.

    Args:
        host (str): IP or hostname of the target server.
        port_range (str): Port range to scan (e.g., "1521-1530").

    Returns:
        list: List of dictionaries containing port, service name, and whether it's encrypted (TCPS).
    """
    scanner = nmap.PortScanner()

    try:
        # Run the Nmap scan with service detection and SSL/TLS script
        print(f"Scanning {host} for open ports in range {port_range}...")
        scanner.scan(
            hosts=host,
            ports=port_range,
            arguments='-sV --script ssl-cert'  # Enables service detection and SSL/TLS identification
        )

        open_ports = []
        for host in scanner.all_hosts():
            for proto in scanner[host].all_protocols():
                ports = scanner[host][proto]
                for port, details in ports.items():
                    if details['state'] == 'open':
                        is_encrypted = 'ssl' in details.get('product', '').lower() or 'tls' in details.get('product',
                                                                                                           '').lower()
                        open_ports.append({
                            'port': port,
                            'service': details.get('name', 'unknown'),
                            'product': details.get('product', 'unknown'),
                            'encrypted': is_encrypted
                        })

        return open_ports

    except Exception as e:
        print(f"Error scanning ports: {e}")
        return []

if __name__ == "__main__":
    # User-defined input
    target_host = input("Enter the target server (IP or hostname): ")
    port_range = input("Enter the port range to scan (e.g., 1521-1530): ")

    results = scan_ports_with_tls_detection(target_host, port_range)
    print("Detected Open Ports:")
    for result in results:
        encryption_status = "TCPS (encrypted)" if result['encrypted'] else "TCP (unencrypted)"
        print(
            f"Port: {result['port']}, Service: {result['service']}, Product: {result['product']}, Encryption: {encryption_status}")