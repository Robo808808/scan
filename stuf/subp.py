import subprocess


def sniff_listening_ports():
    try:
        # Run the ss command to list listening ports
        result = subprocess.run(['ss', '-lt'], capture_output=True, text=True, check=True)
        lines = result.stdout.splitlines()

        listening_ports = []
        for line in lines[1:]:  # Skip the header line
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
        print(f"Error sniffing ports: {e}")
        return []


if __name__ == "__main__":
    ports = sniff_listening_ports()
    print("Listening Ports:")
    for port_info in ports:
        print(f"Protocol: {port_info['protocol']}, Address: {port_info['local_address']}, Port: {port_info['port']}")
