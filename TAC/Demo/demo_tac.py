import datetime, time, oracledb

# You said you already do this before running:
# oracledb.init_oracle_client(lib_dir="/u01/app/oracle/product/19.22/client")

# Full connect descriptor with BOTH hosts (primary & standby).
# Replace <PRI_HOST>, <STBY_HOST>, ports/service as needed.
dsn = (
    "(DESCRIPTION="
      "(CONNECT_TIMEOUT=20)"
      "(TRANSPORT_CONNECT_TIMEOUT=3)"
      "(RETRY_COUNT=60)"
      "(RETRY_DELAY=2)"
      "(ADDRESS_LIST=(LOAD_BALANCE=ON)"
        "(ADDRESS=(PROTOCOL=TCP)(HOST=<PRI_HOST>)(PORT=1521))"
        "(ADDRESS=(PROTOCOL=TCP)(HOST=<STBY_HOST>)(PORT=1521))"
      ")"
      "(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=br_tac_svc))"
    ")"
)

# Use a SessionPool so each loop iteration is a clean request boundary.
# events=True subscribes to FAN in thick mode; threaded=True is required with events.
pool = oracledb.SessionPool(
    user="<USER>",
    password="<PASSWORD>",
    dsn=dsn,
    min=1, max=4, increment=1,
    homogeneous=True,
    threaded=True,
    events=True
)

merge_sql = (
  "MERGE INTO demo_tac_ac t "
  "USING (SELECT :id id, :note note FROM dual) s "
  "ON (t.id = s.id) "
  "WHEN NOT MATCHED THEN INSERT (id, note) VALUES (s.id, s.note)"
)

id_val = 1003
print("Running… upsert every 1s. Do a broker switchover now.")

while True:
    note = f"PY-TAC {datetime.datetime.utcnow().isoformat()}Z"
    try:
        # Borrow → do work → commit → return (boundary for TAC).
        with pool.acquire() as conn:
            conn.autocommit = False
            with conn.cursor() as cur:
                cur.execute(merge_sql, [id_val, note])  # deterministic = replay-safe
            conn.commit()  # commit outcome protected by your service settings
        print(f"Upserted id={id_val} note={note}")
    except oracledb.Error as e:
        # Optional: brief retry on transient connect/reroute noise during role change
        err = getattr(e, "args", [None])[0]
        print(f"hit error {err}, will retry in a moment…")
        time.sleep(2)
    time.sleep(1)