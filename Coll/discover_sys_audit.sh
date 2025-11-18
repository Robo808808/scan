#!/usr/bin/env bash
# discover_sys_audit.sh
# Discover Oracle DBs from /etc/oratab, find audit destinations, scan .aud files,
# and report SYS/SYSTEM logons (remote/local; password heuristics) to a CSV.
#
# Usage:
#   chmod +x discover_sys_audit.sh
#   ./discover_sys_audit.sh [-o /path/to/output.csv] [-n MAX_AUDIT_FILES] [-r ROW_LIMIT]
#
# Defaults:
#   OUTPUT=/tmp/sys_audit_findings.csv
#   MAX_AUDIT_FILES=500   # per SID
#   ROW_LIMIT=200         # DB audit rows pulled per SID
#
# Notes:
# - Run as 'oracle' (OS-auth) so `sqlplus / as sysdba` works.
# - Heuristics for password/local/remote are conservative. Review results manually.

set -euo pipefail

OUTPUT="/tmp/sys_audit_findings.csv"
MAX_AUDIT_FILES=500
ROW_LIMIT=200
ORATAB="/etc/oratab"

while getopts ":o:n:r:t:" opt; do
  case "$opt" in
    o) OUTPUT="$OPTARG" ;;
    n) MAX_AUDIT_FILES="$OPTARG" ;;
    r) ROW_LIMIT="$OPTARG" ;;
    t) ORATAB="$OPTARG" ;;
    *) echo "Usage: $0 [-o output.csv] [-n max_audit_files] [-r row_limit] [-t /path/to/oratab]" >&2; exit 1 ;;
  )
  esac
done

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >&2; }

# --- Helpers ---------------------------------------------------------------

have_sqlplus() { command -v sqlplus >/dev/null 2>&1; }

# Run SQL via sqlplus / as sysdba with minimal formatting; prints lines
run_sql(){
  local sql="$1"
  # shellcheck disable=SC2016
  sqlplus -S "/ as sysdba" <<EOF 2>/dev/null | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//'
SET FEEDBACK OFF HEADING OFF PAGESIZE 0 LINES 32767 TRIMS ON ECHO OFF
${sql}
EXIT
EOF
}

# Query v$parameter value by name (returns one line or empty)
get_param(){
  local p="$1"
  run_sql "SELECT value FROM v\\$parameter WHERE name='${p}';" | head -n 1
}

# Is Unified Auditing enabled?
is_unified(){
  local v
  v="$(run_sql "SELECT value FROM v\\$option WHERE parameter='Unified Auditing';" | tr '[:lower:]' '[:upper:]')"
  [[ "$v" == TRUE* ]]
}

# Pull recent unified audit rows (SYS/SYSTEM logon events)
pull_unified_rows(){
  run_sql "
SELECT TO_CHAR(event_timestamp,'YYYY-MM-DD HH24:MI:SS')||'|'||
       NVL(dbusername,'')||'|'||NVL(client_host,'')||'|'||
       NVL(client_program_name,'')||'|'||NVL(os_username,'')||'|'||
       NVL(TO_CHAR(return_code),'')
FROM unified_audit_trail
WHERE dbusername IN ('SYS','SYSTEM') AND action_name='LOGON'
ORDER BY event_timestamp DESC
FETCH FIRST ${ROW_LIMIT} ROWS ONLY;"
}

# Pull recent traditional audit rows
pull_trad_rows(){
  run_sql "
SELECT TO_CHAR(timestamp,'YYYY-MM-DD HH24:MI:SS')||'|'||
       NVL(username,'')||'|'||NVL(os_username,'')||'|'||
       NVL(userhost,'')||'|'||NVL(terminal,'')||'|'||
       NVL(TO_CHAR(returncode),'')
FROM dba_audit_session
WHERE username IN ('SYS','SYSTEM')
ORDER BY timestamp DESC
FETCH FIRST ${ROW_LIMIT} ROWS ONLY;"
}

# Add ORACLE_HOME/bin to PATH if provided
use_home(){
  local home="$1"
  if [[ -n "$home" && -d "$home/bin" ]]; then
    export ORACLE_HOME="$home"
    export PATH="$home/bin:$PATH"
  fi
}

# --- CSV init --------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT")"
: > "$OUTPUT"
# header
echo "sid,source,file,row,timestamp,dbusername,db_user,action,client_address,client_host,program,client_program,os_username,userhost,terminal,auth,detected_method,detected_location,return_code" >> "$OUTPUT"

append_csv(){
  # all fields quoted, commas inside quotes allowed; embedded quotes doubled
  local IFS=','; local -a fields=()
  for f in "$@"; do
    f="${f//\"/\"\"}"
    fields+=( "\"$f\"" )
  done
  (IFS=,; echo "${fields[*]}") >> "$OUTPUT"
}

# --- Audit file scanning (heuristics) --------------------------------------
# Scan one .aud file and emit zero or more CSV lines (source=audit_file)
scan_aud_file(){
  local sid="$1" f="$2"
  # Read file, split into blocks (blank line or lines of ----), then parse interesting keys
  # We keep it awk-only for portability.
  awk -v SID="$sid" -v FILE="$f" '
    function trim(s){ gsub(/^[ \t\r\n]+|[ \t\r\n]+$/,"",s); return s }
    BEGIN{
      RS=""; FS="\n";
    }
    {
      # one record = one block
      text=$0
      upper=text; gsub(/[a-z]/, "", upper) # rough upper-case copy (not perfect for non-ascii)
      if (upper !~ /DATABASE USER/ || upper !~ /SYS/) next;

      # extract fields with regexes
      db_user=""; action=""; client_address=""; program=""; auth=""; ts=""
      match(text, /DATABASE USER[[:space:]]*:[[:space:]]*['\"]?([A-Za-z0-9_]+)['\"]?/, m); if (m[1]!="") db_user=toupper(m[1])
      match(text, /ACTION[[:space:]]*:[[:space:]]*'\''?([A-Za-z_ ]+)'\''?/, a); if (a[1]!="") action=toupper(trim(a[1]))
      match(text, /CLIENT ADDRESS[[:space:]]*:[[:space:]]*(.*)$/, ca); if (ca[1]!="") client_address=trim(ca[1])
      match(text, /CLIENT HOST[[:space:]]*:[[:space:]]*['\"]?([^\n'\"]+)['\"]?/, ch); if (ch[1]!="") client_address=trim(ch[1])
      match(text, /PROGRAM[[:space:]]*:[[:space:]]*['\"]?([^\n'\"]+)['\"]?/, pr); if (pr[1]!="") program=trim(pr[1])
      match(text, /CLIENT PROGRAM NAME[[:space:]]*:[[:space:]]*['\"]?([^\n'\"]+)['\"]?/, cpr); if (cpr[1]!="") program=trim(cpr[1])
      match(text, /AUTHENTICATION[[:space:]]*:[[:space:]]*['\"]?([A-Za-z0-9_ -]+)['\"]?/, au); if (au[1]!="") auth=toupper(trim(au[1]))
      match(text, /TIMESTAMP[[:space:]]*:[[:space:]]*['\"]?([^\n'\"]+)['\"]?/, ts1); if (ts1[1]!="") ts=trim(ts1[1])
      if (db_user!="SYS" || index(action,"CONNECT")!=1) next

      detected_location="unknown"; detected_method="unknown"
      if (toupper(client_address) ~ /PROTOCOL[[:space:]]*=[[:space:]]*TCP/ || client_address ~ /HOST[[:space:]]*=/ || client_address ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) {
        detected_location="remote"
        if (auth ~ /PASS/) detected_method="password"; else detected_method="likely-password"
      }
      if (toupper(client_address) ~ /PROTOCOL[[:space:]]*=[[:space:]]*BEQ/ || toupper(text) ~ /\bLOCAL\b/ || toupper(text) ~ /BEQ/) {
        detected_location="local"
        if (auth ~ /PASS/) detected_method="password"; else detected_method="local-auth"
      }
      if (tolower(program) ~ /sqlplus/ && detected_method=="unknown") detected_method="possible-password-in-cmdline"

      # emit CSV row (minimal fields for audit_file)
      # columns: sid,source,file,row,timestamp,dbusername,db_user,action,client_address,client_host,program,client_program,os_username,userhost,terminal,auth,detected_method,detected_location,return_code
      gsub(/"/, "\"\"", program); gsub(/"/, "\"\"", client_address); gsub(/"/, "\"\"", auth); gsub(/"/, "\"\"", ts)
      printf "\"%s\",\"%s\",\"%s\",\"\",\"%s\",\"\",\"%s\",\"%s\",\"%s\",\"\",\"%s\",\"\",\"\",\"\",\"\",\"%s\",\"%s\",\"%s\",\"\"\n",
             SID,"audit_file",FILE,ts,"",db_user,action,client_address,program,auth,detected_method,detected_location
    }
  ' "$f" >> "$OUTPUT"
}

scan_audit_dir(){
  local sid="$1" dir="$2"
  [[ -d "$dir" ]] || { log "  [!] audit_file_dest not directory: $dir"; return; }
  local count=0
  while IFS= read -r -d '' f; do
    scan_aud_file "$sid" "$f"
    count=$((count+1))
    if [[ "$MAX_AUDIT_FILES" -gt 0 && "$count" -ge "$MAX_AUDIT_FILES" ]]; then
      break
    fi
  done < <(find "$dir" -type f \( -name '*.aud' -o -name 'ora_*.aud' -o -name '*.log' \) -printf '%T@ %p\0' 2>/dev/null | sort -rz -n -r | cut -z -d' ' -f2-)
  log "  scanned $count audit files in $dir"
}

# --- Parse /etc/oratab -----------------------------------------------------
if [[ ! -f "$ORATAB" ]]; then
  log "[!] $ORATAB not found. Exiting."
  exit 1
fi

mapfile -t ENTRIES < <(awk -F: 'NF>=2 && $0 !~ /^[[:space:]]*#/ && $1!="HOSTNAME"{print $1":"$2}' "$ORATAB")
if [[ ${#ENTRIES[@]} -eq 0 ]]; then
  log "[!] No SIDs found in $ORATAB"
  exit 0
fi

# --- Main loop --------------------------------------------------------------
for ent in "${ENTRIES[@]}"; do
  SID="${ent%%:*}"
  HOME="${ent#*:}"
  export ORACLE_SID="$SID"
  use_home "$HOME"

  log "=== SID: $SID (ORACLE_HOME=${ORACLE_HOME:-<unknown>}) ==="

  if ! have_sqlplus; then
    log "  [!] sqlplus not found in PATH for SID $SID (ORACLE_HOME/bin missing?) — skipping DB queries."
    AUD_DEST="" # still try to guess from common paths?
  fi

  AUD_DEST=""
  AUD_SYSOPS=""
  if have_sqlplus; then
    AUD_DEST="$(get_param "audit_file_dest" | head -n1 || true)"
    AUD_SYSOPS="$(get_param "audit_sys_operations" | tr '[:lower:]' '[:upper:]' | head -n1 || true)"
    [[ -n "$AUD_DEST" ]] && log "  audit_file_dest = $AUD_DEST"
    [[ -n "$AUD_SYSOPS" ]] && log "  audit_sys_operations = $AUD_SYSOPS"

    if is_unified; then
      log "  Unified Auditing: YES"
      while IFS= read -r line; do
        # timestamp|dbusername|client_host|client_program|os_username|return_code
        [[ -z "$line" ]] && continue
        IFS='|' read -r ts dbu chost cprog osuser rcode <<<"$line"
        append_csv "$SID" "unified_audit_trail" "" "$line" "$ts" "$dbu" "" "" "" "$chost" "" "$cprog" "$osuser" "" "" "" "" "" "$rcode"
      done < <(pull_unified_rows || true)
    else
      log "  Unified Auditing: NO (using DBA_AUDIT_SESSION)"
      while IFS= read -r line; do
        # timestamp|username|os_username|userhost|terminal|returncode
        [[ -z "$line" ]] && continue
        IFS='|' read -r ts dbu osuser userhost term rcode <<<"$line"
        append_csv "$SID" "dba_audit_session" "" "$line" "$ts" "$dbu" "" "" "" "" "" "" "$osuser" "$userhost" "$term" "" "" "" "$rcode"
      done < <(pull_trad_rows || true)
    fi
  fi

  # Scan OS audit files (adump)
  if [[ -n "$AUD_DEST" && -d "$AUD_DEST" ]]; then
    log "  scanning audit directory: $AUD_DEST"
    scan_audit_dir "$SID" "$AUD_DEST"
  else
    # Try common fallbacks based on SID/HOME (best-effort)
    for guess in \
      "${HOME%/*/*}/admin/$SID/adump" \
      "${HOME%/*}/admin/$SID/adump" \
      "/u01/app/oracle/admin/$SID/adump" \
      "/opt/oracle/admin/$SID/adump" \
      "/var/opt/oracle/admin/$SID/adump"
    do
      if [[ -d "$guess" ]]; then
        log "  using fallback audit dir: $guess"
        scan_audit_dir "$SID" "$guess"
        break
      fi
    done
  fi
done

log "Done. CSV: $OUTPUT"

# --- Quick tail (optional) --------------------------------------------------
# tail -n 20 "$OUTPUT"
