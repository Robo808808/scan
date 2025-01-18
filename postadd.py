import psycopg2
from psycopg2.extras import execute_batch

# Database connection details
DB_CONFIG = {
    "dbname": "your_database",
    "user": "your_user",
    "password": "your_password",
    "host": "your_host",
    "port": "5432",
}

# Connect to PostgreSQL
def connect_to_db():
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        print("Connected to the database successfully.")
        return conn
    except Exception as e:
        print(f"Error connecting to the database: {e}")
        return None

# Insert a single row into the hostscan table
def insert_single_row(assetid, hostname, instancename, port):
    query = """
    INSERT INTO hostscan (assetid, hostname, instancename, port)
    VALUES (%s, %s, %s, %s)
    """
    try:
        conn = connect_to_db()
        if conn:
            with conn.cursor() as cursor:
                cursor.execute(query, (assetid, hostname, instancename, port))
                conn.commit()
                print(f"Inserted: {assetid}, {hostname}, {instancename}, {port}")
    except Exception as e:
        print(f"Error inserting row: {e}")
    finally:
        if conn:
            conn.close()

# Bulk insert rows into the hostscan table
def insert_bulk_rows(data):
    """
    Args:
        data (list of tuples): Each tuple contains (assetid, hostname, instancename, port).
    """
    query = """
    INSERT INTO hostscan (assetid, hostname, instancename, port)
    VALUES (%s, %s, %s, %s)
    """
    try:
        conn = connect_to_db()
        if conn:
            with conn.cursor() as cursor:
                # Use execute_batch for efficient bulk inserts
                execute_batch(cursor, query, data)
                conn.commit()
                print(f"Bulk inserted {len(data)} rows successfully.")
    except Exception as e:
        print(f"Error during bulk insert: {e}")
    finally:
        if conn:
            conn.close()

# Example usage
if __name__ == "__main__":
    # Single row insert
    insert_single_row(1, "server01", "oracle-instance01", 1521)

    # Bulk insert
    bulk_data = [
        (2, "server02", "oracle-instance02", 1522),
        (3, "server03", "oracle-instance03", 1523),
        (4, "server04", "oracle-instance04", 1524),
    ]
    insert_bulk_rows(bulk_data)
