#!/bin/bash

FASTAPI_URL="https://central.server.example.com/submit"
HOSTNAME=$(hostname -s)

# Requires jq on the target host
PAYLOAD="[]"

# Helper: append result to JSON payload
add_result() {
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

# Helper: run SQL and return a single trimmed line
run_sql_scalar() {
  sqlplus -s / as sysdba <<EOF | awk 'NF {print $1; exit}'
set heading off feedback off verify off termout off pages 0 lines 200
$1
exit
EOF
}

# Loop over /etc/oratab  (FIXED: no subshell)
while IFS=: read -r SID ORA_HOME _FLAG; do
  [ -z "$SID" ] && continue
  export ORACLE_SID="$SID"
  export ORACLE_HOME="$ORA_HOME"
  export PATH="$ORACLE_HOME/bin:$PATH"

  # PDB name (if CDB)
  PDB=$(sqlplus -s / as sysdba <<EOF
set heading off feedback off verify off termout off pages 0 lines 200
set serveroutput on
declare
  l_is_cdb varchar2(3);
  l_pdb    varchar2(128);
begin
  select cdb into l_is_cdb from v\$database;
  if l_is_cdb = 'YES' then
    select name into l_pdb from v\$pdbs
    where open_mode = 'READ WRITE'
    fetch first 1 rows only;
    dbms_output.put_line(l_pdb);
  else
    dbms_output.put_line('');
  end if;
end;
/
exit
EOF
)
  PDB=$(echo "$PDB" | tr -d '[:space:]')

  ### 1. Password file check ###
  PWFILE="$ORACLE_HOME/dbs/orapw$SID"
  if [[ -f "$PWFILE" ]]; then
    add_result "$SID" "$PDB" "password_file" "$PWFILE" "PASS"
  else
    add_result "$SID" "$PDB" "password_file" "not found" "FAIL"
  fi

  ### 2. DB links owned by SYS/SYSTEM ###
  DBLINKS=$(run_sql_scalar "select count(*) from dba_db_links where owner in ('SYS','SYSTEM');")
  DBLINKS=${DBLINKS:-0}
  if [[ "$DBLINKS" =~ ^[0-9]+$ ]] && [[ "$DBLINKS" -eq 0 ]]; then
    add_result "$SID" "$PDB" "sys_dblinks" "0" "PASS"
  else
    add_result "$SID" "$PDB" "sys_dblinks" "$DBLINKS" "FAIL"
  fi

  ### 3. SYSTEM user session auditing ###
  AUD=$(run_sql_scalar "select count(*) from dba_stmt_audit_opts where user_name='SYSTEM';")
  AUD=${AUD:-0}
  if [[ "$AUD" =~ ^[0-9]+$ ]] && [[ "$AUD" -gt 0 ]]; then
    add_result "$SID" "$PDB" "audit_system" "$AUD" "PASS"
  else
    add_result "$SID" "$PDB" "audit_system" "none" "FAIL"
  fi

  ### 4. SYS audit CSV from OS (optional) ###
  CSV_FILE="/tmp/sys_audit_${SID}.csv"
  if [[ -f "$CSV_FILE" ]]; then
    CSV_CONTENT=$(base64 "$CSV_FILE")
    add_result "$SID" "$PDB" "sys_audit_csv" "$CSV_CONTENT" "INFO"
  fi

done < <(grep -v '^#' /etc/oratab | grep -E ":[Y|N]$")

# Optional: debug
# echo "$PAYLOAD"

# Send one JSON payload for all DBs on host
curl -s -X POST "$FASTAPI_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" >/dev/null 2>&1
