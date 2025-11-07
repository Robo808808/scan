import sqlite3
import json

# Initialize the SQLite database (creates the file if it doesn't exist)
def init_db():
    conn = sqlite3.connect('results.db')
    c = conn.cursor()
    c.execute('''
        CREATE TABLE IF NOT EXISTS listener_results (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            function TEXT,
            results TEXT
        )
    ''')
    conn.commit()
    conn.close()

# Insert result into the database with function name and JSON serialized result
def insert_result(function_name, results):
    conn = sqlite3.connect('results.db')
    c = conn.cursor()
    c.execute('''
        INSERT INTO listener_results (function, results)
        VALUES (?, ?)
    ''', (function_name, json.dumps(results)))  # Serialize the results as JSON
    conn.commit()
    conn.close()
