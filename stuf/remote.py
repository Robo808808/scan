import paramiko


def sniff_remote_ports(host, username, password=None, key_file=None):
    """
    Connects to a remote server via SSH and retrieves listening TCP and TCPS ports.

    Args:
        host (str): Remote server IP or hostname.
        username (str): SSH username.
        password (str): SSH password (if not using key-based authentication).
        key_file (str): Path to the private key file (optional).

    Returns:
        list: A list of dictionaries containing protocol, address, and port details.
    """
    try:
        # Initialize the SSH client
        ssh_client = paramiko.SSHClient()
        ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        # Connect to the remote server
        if key_file:
            ssh_client.connect(host, username=username, key_filename=key_file)
        else:
            ssh_client.connect(host, username=username, password=password)

        # Execute the command to list listening ports
        command = "ss -lt"
        stdin, stdout, stderr = ssh_client.exec_command(command)
        output = stdout.read().decode()
        error = stderr.read().decode()

        if error:
            raise Exception(f"Error executing command: {error}")

        # Parse the output
        listening_ports = []
        lines = output.splitlines()
        for line in lines[1:]:  # Skip the header
            parts = line.split()
            if len(parts) >= 5:
                proto = parts[0]  # Protocol (e.g., tcp)
                local_address = parts[3]  # Local address and port
                address, port = local_address.rsplit(':', 1)
                listening_ports.append({
                    'protocol': proto.upper(),
                    'local_address': address,
                    'port': port
                })

        return listening_ports

    except Exception as e:
        print(f"Failed to sniff ports on {host}: {e}")
        return []

    finally:
        ssh_client.close()


if __name__ == "__main__":
    # Example usage
    remote_host = "localhost"  # Replace with the remote server's IP or hostname
    username = "your_username"
    password = "your_password"  # Use None if using key-based authentication
    key_file = None  # Provide the path to your SSH private key if applicable

    ports = sniff_remote_ports(remote_host, username, password, key_file)
    print("Listening Ports on Remote Server:")
    for port_info in ports:
        print(f"Protocol: {port_info['protocol']}, Address: {port_info['local_address']}, Port: {port_info['port']}")
