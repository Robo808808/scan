import time, datetime, oracledb

# Initialize Thick mode once in your app startup (if not already done)
# oracledb.init_oracle_client(lib_dir="/opt/oracle/instantclient_19_20")

conn = oracledb.connect(user="<USER>", password="<PASSWORD>",
                        dsn="//<SCAN-or-host>:1521/br_tac_svc")  # service required
conn.autocommit = False

sql = ( "MERGE INTO demo_tac_ac t "
        "USING (SELECT :id id, :note note FROM dual) s "
        "ON (t.id = s.id) "
        "WHEN NOT MATCHED THEN INSERT (id, note) VALUES (s.id, s.note)" )

cur = conn.cursor()
id_val = 1003

print("Running… update every 1s. Perform a switchover now.")
while True:
    note = f"PY-TAC {datetime.datetime.utcnow().isoformat()}Z"
    cur.execute(sql, [id_val, note])  # replay-safe request
    conn.commit()                      # commit outcome enforced by service
    print(f"Upserted id={id_val} note={note}")
    time.sleep(1)
