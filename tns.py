import socket
def probe_oracle_listener(host, port):
    tns_probe = b"\x00\x3a\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x35\x00\x00\x0c\x01\x2c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(2)
            sock.connect((host, port))
            sock.sendall(tns_probe)
            response = sock.recv(1024)
            if b"ERROR" in response and b"Oracle" in response:
                return True
    except Exception:
        pass
    return False

def find_oracle_port(host, port_range):
    for port in range(port_range[0], port_range[1] + 1):
        if probe_oracle_listener(host, port):
            print(f"Oracle listener detected on port {port}")
            return port
    print("Oracle listener not found in the specified range.")
    return None

if __name__ == "__main__":
    server = "localhost"  # Replace with your target server IP
    port_range = (1521, 1530)  # Typical Oracle listener range
    find_oracle_port(server, port_range)
