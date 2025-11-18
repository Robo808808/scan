#!/bin/bash

FASTAPI_URL="https://central.server.example.com/submit"
HOSTNAME=$(hostname -s)
PAYLOAD="[]"


function add_result() {
  local sid="$1"
  local pdb="$2"
  local check_name="$3"
  local result="$4"
  local status="$5"

  PAYLOAD=$(jq -c \
    --arg sid "$sid" \
    --arg pdb "$pdb" \
    --arg chk "$check_name" \
    --arg res "$result" \
    --arg st "$status" \
    --arg host "$HOSTNAME" \
    '. += [{
      "hostname": $host,
      "oracle_sid": $sid,
      "pdb_name": $pdb,
      "check_name": $chk,
      "result": $res,
      "status": $st
    }]' <<< "$PAYLOAD")
}

for entry in $(grep -v '^#' /etc/oratab | grep -E ":[Y|N]$"); do
  SID=$(echo "$entry" | cut -d: -f1)
  ORA_HOME=$(echo "$entry" | cut -d: -f2)
  export ORACLE_SID="$SID"
  export ORACLE_HOME="$ORA_HOME"
  export PATH="$ORACLE_HOME/bin:$PATH"

  PDB=$(sqlplus -s / as sysdba <<EOF
set heading off feedback off pages 0
select case when cdb='YES' then (select name from v\$pdbs where open_mode='READ WRITE' fetch first 1 rows only)
            else null end from v\$database;
EOF
)

  # password file
  [[ -f "$ORACLE_HOME/dbs/orapw$SID" ]] \
    && add_result "$SID" "$PDB" "password_file" "$ORACLE_HOME/dbs/orapw$SID" "PASS" \
    || add_result "$SID" "$PDB" "password_file" "not found" "FAIL"

  # SYS/SYSTEM DB links
  DBLINKS=$(sqlplus -s / as sysdba <<< "select count(*) from dba_db_links where owner in ('SYS','SYSTEM');")
  [[ "$DBLINKS" -eq 0 ]] \
    && add_result "$SID" "$PDB" "sys_dblinks" "0" "PASS" \
    || add_result "$SID" "$PDB" "sys_dblinks" "$DBLINKS" "FAIL"

  # SYSTEM auditing
  AUD=$(sqlplus -s / as sysdba <<< "select count(*) from dba_stmt_audit_opts where user_name='SYSTEM';")
  [[ "$AUD" -gt 0 ]] \
    && add_result "$SID" "$PDB" "audit_system" "$AUD" "PASS" \
    || add_result "$SID" "$PDB" "audit_system" "none" "FAIL"

  # SYS audit CSV from OS
  CSV_FILE="/tmp/sys_audit_${SID}.csv"
  if [[ -f "$CSV_FILE" ]]; then
    CSV_CONTENT=$(base64 "$CSV_FILE")  # safely transport
    add_result "$SID" "$PDB" "sys_audit_csv" "$CSV_CONTENT" "INFO"
  fi
done

curl -s -X POST "$FASTAPI_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" >/dev/null 2>&1
