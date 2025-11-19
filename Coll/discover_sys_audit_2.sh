#!/usr/bin/env bash
set -euo pipefail

OUTPUT="/tmp/sys_password_logons.csv"
ORATAB="/etc/oratab"
ROW_LIMIT=200

while getopts ":o:t:r:" opt; do
  case "$opt" in
    o) OUTPUT="$OPTARG" ;;
    t) ORATAB="$OPTARG" ;;
    r) ROW_LIMIT="$OPTARG" ;;
  esac
done

echo "sid,timestamp,os_user,client_host,program,return_code,auth_type" > "$OUTPUT"

run_sql() {
  sqlplus -S "/ as sysdba" <<EOF | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
SET FEEDBACK OFF HEADING OFF PAGES 0 LINES 2000 TRIMS ON
$1
EXIT
EOF
}

mapfile -t DBs < <(awk -F: '$1 && $1!~/^#/ {print $1":"$2}' "$ORATAB")

for entry in "${DBs[@]}"; do
  SID=${entry%%:*}
  HOME=${entry#*:}
  export ORACLE_SID="$SID" ORACLE_HOME="$HOME"
  PATH="$HOME/bin:$PATH"

  echo "=== $SID ===" >&2

  if run_sql "select 1 from dual" >/dev/null 2>&1; then
    if run_sql "SELECT value FROM v\\$option WHERE parameter='Unified Auditing';" \
         | grep -iq true; then

      run_sql "
      SELECT
        TO_CHAR(event_timestamp,'YYYY-MM-DD HH24:MI:SS')||','||
        NVL(os_username,'')||','||
        NVL(client_host,'')||','||
        NVL(client_program_name,'')||','||
        NVL(TO_CHAR(return_code),'')||','||
        CASE WHEN return_code IN (0, 1017) THEN 'PASSWORD' ELSE 'OS-AUTH' END
      FROM unified_audit_trail
      WHERE dbusername='SYS' AND action_name='LOGON'
      ORDER BY event_timestamp DESC
      FETCH FIRST ${ROW_LIMIT} ROWS ONLY;
      " | sed "s/^/$SID,/" >> "$OUTPUT"

    else
      run_sql "
      SELECT
        TO_CHAR(timestamp,'YYYY-MM-DD HH24:MI:SS')||','||
        NVL(os_username,'')||','||
        NVL(userhost,'')||','||
        NVL(terminal,'')||','||
        NVL(TO_CHAR(returncode),'')||','||
        CASE WHEN returncode IN (0, 1017) THEN 'PASSWORD' ELSE 'OS-AUTH' END
      FROM dba_audit_session
      WHERE username='SYS'
      ORDER BY timestamp DESC
      FETCH FIRST ${ROW_LIMIT} ROWS ONLY;
      " | sed "s/^/$SID,/" >> "$OUTPUT"
    fi
  fi
done

echo "Done → $OUTPUT"
