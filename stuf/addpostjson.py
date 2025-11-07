import psycopg2
from psycopg2.extras import execute_batch
import json
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

# PostgreSQL connection details
DB_CONFIG = {
    "dbname": "your_database",
    "user": "your_user",
    "password": "your_password",
    "host": "your_host",
    "port": "5432",
}


def connect_to_db():
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        return conn
    except Exception as e:
        print(f"Error connecting to the database: {e}")
        return None


def insert_services_from_json(assetid, hostname, json_data):
    """
    Insert services from a JSON response into the hostscan table.

    Args:
        assetid (int): The asset ID.
        hostname (str): The server hostname.
        json_data (str): JSON response with service and instance details.
    """
    query = """
    INSERT INTO hostscan (assetid, hostname, instancename, port)
    VALUES (%s, %s, %s, %s)
    """
    try:
        conn = connect_to_db()
        if conn:
            with conn.cursor() as cursor:
                services = json.loads(json_data)  # Parse JSON string to list of dicts

                # Create data for insertion (e.g., placeholder port 1521)
                data = [
                    (assetid, hostname, service['instance'], 1521)  # Replace with actual port if available
                    for service in services
                ]

                # Insert data into the table
                execute_batch(cursor, query, data)
                conn.commit()
                print(f"Inserted {len(data)} rows into the database.")
    except Exception as e:
        print(f"Error inserting services: {e}")
    finally:
        if conn:
            conn.close()


if __name__ == "__main__":
    # Example usage
    asset_id = 1
    hostname = "server01"

    # Get services as JSON
    json_services = get_oracle_services()

    # Insert into PostgreSQL table
    insert_services_from_json(asset_id, hostname, json_services)
