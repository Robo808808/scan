from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
import sqlite3, time, hashlib

DB = "central.db"
app = FastAPI()
templates = Jinja2Templates(directory="templates")


class Assessment(BaseModel):
    hostname: str
    oracle_sid: str
    pdb_name: str | None = None
    check_name: str
    result: str
    status: str


# -------------------- DB Initialization --------------------
def init_db():
    with sqlite3.connect(DB) as conn:
        cur = conn.cursor()

        cur.execute("""
        CREATE TABLE IF NOT EXISTS db_assessment_results (
            hostname TEXT NOT NULL,
            oracle_sid TEXT NOT NULL,
            pdb_name TEXT,
            check_name TEXT NOT NULL,
            result TEXT NOT NULL,
            status TEXT NOT NULL,
            hash TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            PRIMARY KEY (hostname, oracle_sid, pdb_name, check_name)
        );
        """)

        cur.execute("""
        CREATE TABLE IF NOT EXISTS db_assessment_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            hostname TEXT NOT NULL,
            oracle_sid TEXT NOT NULL,
            pdb_name TEXT,
            check_name TEXT NOT NULL,
            result TEXT NOT NULL,
            status TEXT NOT NULL,
            hash TEXT NOT NULL,
            timestamp TEXT NOT NULL
        );
        """)

        conn.commit()

init_db()
# -----------------------------------------------------------


@app.post("/submit")
def submit(data: list[Assessment]):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    inserted = updated = 0

    with sqlite3.connect(DB) as conn:
        cur = conn.cursor()

        for item in data:
            new_hash = hashlib.sha256(item.result.encode()).hexdigest()
            row = cur.execute("""
                SELECT hash FROM db_assessment_results
                WHERE hostname = ? AND oracle_sid = ? AND pdb_name = ? AND check_name = ?
            """, (item.hostname, item.oracle_sid, item.pdb_name, item.check_name)).fetchone()

            if row and row[0] == new_hash:
                continue  # no change

            # store in history if previous record existed
            if row:
                updated += 1
            else:
                inserted += 1

            # INSERT/REPLACE into main table
            cur.execute("""
                INSERT OR REPLACE INTO db_assessment_results
                (hostname, oracle_sid, pdb_name, check_name, result, status, hash, timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (item.hostname, item.oracle_sid, item.pdb_name,
                  item.check_name, item.result, item.status, new_hash, ts))

            # insert into history
            cur.execute("""
                INSERT INTO db_assessment_history
                (hostname, oracle_sid, pdb_name, check_name, result, status, hash, timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (item.hostname, item.oracle_sid, item.pdb_name,
                  item.check_name, item.result, item.status, new_hash, ts))

        conn.commit()

    return {"received": len(data), "inserted": inserted, "updated": updated}


@app.get("/latest_failures")
def latest_failures():
    with sqlite3.connect(DB) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        rows = cur.execute("""
            SELECT * FROM db_assessment_results
            WHERE status = 'FAIL'
            ORDER BY timestamp DESC
        """).fetchall()
    return [dict(r) for r in rows]


@app.get("/stats")
def stats():
    with sqlite3.connect(DB) as conn:
        cur = conn.cursor()

        by_status = cur.execute("""
            SELECT status, COUNT(*) FROM db_assessment_results GROUP BY status
        """).fetchall()

        by_host = cur.execute("""
            SELECT hostname, status, COUNT(*)
            FROM db_assessment_results GROUP BY hostname, status
        """).fetchall()

    return {
        "global_status_counts": {row[0]: row[1] for row in by_status},
        "per_host": [{"hostname": h, "status": s, "count": c} for h, s, c in by_host]
    }


@app.get("/changes")
def changes(limit: int = 100):
    with sqlite3.connect(DB) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        rows = cur.execute("""
            SELECT * FROM db_assessment_history
            ORDER BY timestamp DESC
            LIMIT ?
        """, (limit,)).fetchall()
    return [dict(r) for r in rows]


# ---------------------- HTML dashboard ----------------------
@app.get("/dashboard", response_class=HTMLResponse)
def dashboard(request: Request):
    with sqlite3.connect(DB) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        rows = cur.execute("""
            SELECT hostname, oracle_sid, pdb_name, check_name,
                   result, status, timestamp
            FROM db_assessment_results
            ORDER BY hostname, oracle_sid, check_name
        """).fetchall()

    return templates.TemplateResponse(
        "dashboard.html", {"request": request, "rows": rows}
    )
