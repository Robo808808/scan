import subprocess
import re

def get_listening_ports():
    print("Listening Ports and Processes:")
    #result = subprocess.run(['netstat', '-tulnp'], capture_output=True, text=True)
    result = subprocess.run(['ss', '-tulnp'], capture_output=True, text=True)
    print(result.stdout)

def get_oracle_services():
    print("\nOracle Listener Services:")
    result = subprocess.run(['lsnrctl', 'status'], capture_output=True, text=True)
    services = re.findall(r'Service\s+"(.+?)".*?Instance\s+"(.+?)"', result.stdout)
    for service, instance in services:
        print(f"Service: {service}, Instance: {instance}")

if __name__ == "__main__":
    get_listening_ports()
    get_oracle_services()