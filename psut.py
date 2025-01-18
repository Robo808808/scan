import psutil

def sniff_listening_ports():
    listening_ports = []
    for conn in psutil.net_connections(kind='inet'):
        if conn.status == 'LISTEN':
            proto = 'TCP'
            if conn.laddr.port == 443:  # Example condition for TCPS
                proto = 'TCPS'
            listening_ports.append({
                'protocol': proto,
                'local_address': conn.laddr.ip,
                'port': conn.laddr.port
            })

    return listening_ports

if __name__ == "__main__":
    ports = sniff_listening_ports()
    print("Listening Ports:")
    for port_info in ports:
        print(f"Protocol: {port_info['protocol']}, Address: {port_info['local_address']}, Port: {port_info['port']}")
