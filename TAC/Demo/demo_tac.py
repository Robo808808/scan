import datetime, time, oracledb

# Thick mode (you already do this step before running the script)
# oracledb.init_oracle_client(lib_dir="...")

# Easy Connect+ descriptor: include BOTH primary & standby SCANs for site failover
dsn = ("(DESCRIPTION="
       "(CONNECT_TIMEOUT=90)(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=50)(RETRY_DELAY=3)"
       "(ADDRESS_LIST=(LOAD_BALANCE=ON)"
         "(ADDRESS=(PROTOCOL=TCP)(HOST=<PRIMARY-SCAN>)(PORT=1521))"
         "(ADDRESS=(PROTOCOL=TCP)(HOST=<STANDBY-SCAN>)(PORT=1521)))"
       "(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=br_tac_svc)))")

pool = oracledb.SessionPool(
    user="<USER>", password="<PASSWORD>", dsn=dsn,
    min=1, max=4, increment=1, homogeneous=True, threaded=True
)

sql = (
  "MERGE INTO demo_tac_ac t "
  "USING (SELECT :id id, :note note FROM dual) s "
  "ON (t.id = s.id) "
  "WHEN NOT MATCHED THEN INSERT (id, note) VALUES (s.id, s.note)"
)

id_val = 1003
print("Running… update every 1s. Perform a broker switchover now.")
while True:
    note = f"PY-TAC {datetime.datetime.utcnow().isoformat()}Z"
    with pool.acquire() as conn:
        conn.autocommit = False
        with conn.cursor() as cur:
            cur.execute(sql, [id_val, note])   # deterministic, replay-safe
        conn.commit()                           # commit outcome enforced by service
    print(f"Upserted id={id_val} note={note}")
    time.sleep(1)

