import socket

def scan_ports(host, port_range):
    open_ports = []
    for port in range(port_range[0], port_range[1] + 1):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(1)  # Timeout for the connection
            result = sock.connect_ex((host, port))
            if result == 0:
                open_ports.append(port)
    return open_ports

if __name__ == "__main__":
    target_host = "localhost"  # Replace with the target server's IP
    ports = scan_ports(target_host, (20, 30))  # Scan ports 1-1024
    print(f"Open ports on {target_host}: {ports}")
