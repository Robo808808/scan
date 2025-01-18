import subprocess
import re
import json


def get_oracle_services():
    """
    Query the Oracle listener using lsnrctl status and return services as a JSON response.

    Returns:
        dict: JSON object with service and instance details.
    """
    try:
        result = subprocess.run(['lsnrctl', 'status'], capture_output=True, text=True)

        # Extract services and instances using regular expressions
        services = re.findall(r'Service\s+"(.+?)".*?Instance\s+"(.+?)"', result.stdout)

        # Format the services into a JSON-compatible dictionary
        services_data = [
            {"service": service, "instance": instance}
            for service, instance in services
        ]

        return json.dumps(services_data)  # Convert to JSON string

    except Exception as e:
        print(f"Error querying Oracle listener: {e}")
        return json.dumps({"error": str(e)})
