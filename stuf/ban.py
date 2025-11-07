import socket

def banner_grab(host, port):
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(2)  # Timeout for the connection
            sock.connect((host, port))
            sock.sendall(b'\n')  # Send a newline to trigger a response
            banner = sock.recv(1024).decode('utf-8', errors='ignore')
            return banner
    except Exception as e:
        return None

def find_oracle_listener(host, port_range):
    for port in range(port_range[0], port_range[1] + 1):
        banner = banner_grab(host, port)
        if banner and "Oracle" in banner:
            print(f"Oracle listener detected on port {port}: {banner.strip()}")
            return port
    print("Oracle listener not found in the specified port range.")
    return None

if __name__ == "__main__":
    server = "localhost"  # Replace with the server IP
    port_range = (1521, 1530)  # Typical Oracle listener port range
    find_oracle_listener(server, port_range)
