# SQLite Table DDL

CREATE TABLE IF NOT EXISTS oracle_endpoints (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  hostname TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  first_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_oracle_endpoints_host ON oracle_endpoints(hostname);

CREATE UNIQUE INDEX IF NOT EXISTS uq_oracle_endpoints_host_endpoint ON oracle_endpoints(hostname, endpoint);

# FastAPI Route — Accept JSON from the Bash Script

from fastapi import APIRouter, HTTPException, Request
import sqlite3
import datetime

router = APIRouter()

DB_PATH = "/path/to/your/database.db"   # update for your app

@router.post("/collect/oracle/endpoints")
async def collect_oracle_endpoints(request: Request):
    """
    Payload format expected:
    {
      "hostname": [ "host:port/service", "host:port/service2", ... ]
    }
    """
    data = await request.json()

    if not isinstance(data, dict) or len(data.keys()) != 1:
        raise HTTPException(status_code=400, detail="Invalid payload format")

    hostname = list(data.keys())[0]
    endpoints = data[hostname]

    if not isinstance(endpoints, list):
        raise HTTPException(status_code=400, detail="Payload value must be a list")

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    for ep in endpoints:
        # Insert new or update last_seen if exists
        cur.execute("""
            INSERT INTO oracle_endpoints(hostname, endpoint)
            VALUES(?, ?)
            ON CONFLICT(hostname, endpoint) DO UPDATE
            SET last_seen = ?
        """, (hostname, ep, datetime.datetime.utcnow()))

    conn.commit()
    conn.close()

    return {"status": "ok", "hostname": hostname, "count": len(endpoints)}

#FastAPI Route — Retrieve Latest Endpoints for a Host
@router.get("/oracle/endpoints/{hostname}")
def get_oracle_endpoints(hostname: str):
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute("""
        SELECT endpoint
        FROM oracle_endpoints
        WHERE hostname = ?
        ORDER BY endpoint
    """, (hostname,))
    rows = cur.fetchall()
    conn.close()

    return {
        "hostname": hostname,
        "endpoints": [r[0] for r in rows]
    }

# FastAPI Route — Retrieve All Known Endpoints (Grouped)
@router.get("/oracle/endpoints")
def get_all_oracle_endpoints():
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute("""
        SELECT hostname, endpoint
        FROM oracle_endpoints
        ORDER BY hostname, endpoint
    """)
    rows = cur.fetchall()
    conn.close()

    result = {}
    for host, ep in rows:
        result.setdefault(host, []).append(ep)

    return result
