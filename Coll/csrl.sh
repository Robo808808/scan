#!/usr/bin/env bash
set -eu

FASTAPI_URL="https://your-fastapi-server/api/submit"   # change to your endpoint
OUT="/tmp/sys_logons_all_hosts.csv"
ORATAB="/etc/oratab"
MAX=800    # max audit files per SID

HOSTNAME=$(hostname -s)

echo "hostname,sid,timestamp,file,database_user,client_address,client_user,status,action" > "$OUT"

parse_aud() {
  SID="$1"
  FILE="$2"
  awk -v FILE="$FILE" -v SID="$SID" -v H="$HOSTNAME" '
    BEGIN { RS=""; FS="\n" }
    {
      ts = $1; dbu = ""; addr = ""; cuser = ""; status = ""; act = ""

      for (i = 1; i <= NF; i++) {
        line = $i
        gsub(/^[ \t]+|[ \t]+$/, "", line)

        if (toupper(line) ~ /^DATABASE USER/) { n = split(line,a,"'\''"); if (n>=2) dbu=toupper(a[2]) }
        if (toupper(line) ~ /^CLIENT ADDRESS/) { n = split(line,a,"'\''"); if (n>=2) addr=a[2] }
        if (toupper(line) ~ /^CLIENT USER/) { n = split(line,a,"'\''"); if (n>=2) cuser=a[2] }
        if (toupper(line) ~ /^STATUS/) { n = split(line,a,"'\''"); if (n>=2) status=a[2] }
        if (toupper(line) ~ /^ACTION/) { n = split(line,a,"'\''"); if (n>=2) act=a[2] }
      }

      if (dbu != "SYS") next
      if (addr ~ /^[ \t]*$/) next

      gsub(/"/,"\"\"",ts); gsub(/"/,"\"\"",addr); gsub(/"/,"\"\"",cuser)
      gsub(/"/,"\"\"",status); gsub(/"/,"\"\"",act)

      printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n",
             H, SID, ts, FILE, dbu, addr, cuser, status, act
    }
  ' "$FILE"
}

# read /etc/oratab
awk -F: 'NF>=2 && $1!~/^#/ {print $1":"$2}' "$ORATAB" | while IFS=: read -r SID HOME; do
  export ORACLE_SID="$SID" ORACLE_HOME="$HOME" PATH="$HOME/bin:$PATH"

  AUD=$(sqlplus -S "/ as sysdba" <<EOF | awk 'NF{print $1; exit}'
SET HEADING OFF FEEDBACK OFF PAGES 0
SELECT value FROM v\$parameter WHERE name='audit_file_dest';
EOF
  ) || AUD=""

  [ -d "$AUD" ] || continue

  count=0
  find "$AUD" -type f \( -name "*.aud" -o -name "ora_*" -o -name "*.log" \) \
    -printf "%T@ %p\n" 2>/dev/null \
    | sort -nr \
    | awk '{print $2}' \
    | while read -r FILE; do
        parse_aud "$SID" "$FILE" >> "$OUT"
        count=$((count+1))
        [ "$count" -ge "$MAX" ] && break
      done
done

echo "CSV ready: $OUT"

# POST each row to FastAPI
tail -n +2 "$OUT" | while IFS= read -r row; do
  curl -s -X POST "$FASTAPI_URL" \
    -H "Content-Type: application/json" \
    -d "{\"hostname\":\"$HOSTNAME\",\"csv_row\":\"$row\"}" >/dev/null || true
done

echo "Posted to FastAPI: $FASTAPI_URL"
