#!/usr/bin/env bash
set -euo pipefail

FASTAPI_URL="https://your-fastapi-server/api/submit"   # URL of your FastAPI endpoint
HOSTNAME=$(hostname -s)
ORATAB="/etc/oratab"
MAX_FILES=800     # per SID
TMP="/tmp/sys_remote_logons_$$.csv"

echo "hostname,sid,timestamp,file,client_address,program,auth_method" > "$TMP"

parse_aud() {
  local SID="$1" FILE="$2"
  awk -v SID="$SID" -v H="$HOSTNAME" -v FILE="$FILE" '
    BEGIN { RS=""; FS="\n" }
    {
      ts=""; dbu=""; addr=""; cuser=""; prog=""; status=""

      # First line = timestamp (Oracle always prints it on top)
      ts=$1

      for (i=1; i<=NF; i++) {
        line=$i
        gsub(/^[ \t]+|[ \t]+$/,"",line)

        if (toupper(line) ~ /^DATABASE USER/) {
          sub(/.*'\''/,"",line); sub(/'\''.*$/,"",line); dbu=toupper(line)
        }
        if (toupper(line) ~ /^CLIENT ADDRESS/) {
          sub(/.*'\''/,"",line); sub(/'\''.*$/,"",line); addr=line
        }
        if (toupper(line) ~ /^CLIENT USER/) {
          sub(/.*'\''/,"",line); sub(/'\''.*$/,"",line); cuser=line
        }
        if (toupper(line) ~ /^STATUS/) {
          sub(/.*'\''/,"",line); sub(/'\''.*$/,"",line); status=line
        }
        if (toupper(line) ~ /^ACTION /) {
          sub(/.*'\''/,"",line); sub(/'\''.*$/,"",line); prog=line
        }
      }

      # Filters
      if (dbu != "SYS") next
      if (addr ~ /^[ \t]*$/) next            # no network = local logon
      # If client user is oracle → likely OS-auth instead of password
      if (toupper(cuser) == "ORACLE") next

      if (prog == "") prog="unknown"
      if (status == "") status="unknown"
      gsub(/"/,"\"\"",ts); gsub(/"/,"\"\"",addr); gsub(/"/,"\"\"",prog); gsub(/"/,"\"\"",status)

      printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n",
             H, SID, ts, FILE, addr, prog, status
    }
  ' "$FILE"
}

# Discover SIDs
mapfile -t ENTRIES < <(awk -F: 'NF>=2 && $0 !~ /^#/ {print $1":"$2}' "$ORATAB")

for ent in "${ENTRIES[@]}"; do
  SID="${ent%%:*}"
  HOME="${ent#*:}"
  export ORACLE_SID="$SID" ORACLE_HOME="$HOME"

  AUD="$(sqlplus -S "/ as sysdba" <<EOF | awk 'NF {print $1; exit}'
SET PAGES 0 FEEDBACK OFF HEADING OFF
SELECT value FROM v\$parameter WHERE name='audit_file_dest';
EOF
  )" || AUD=""

  [[ -z "$AUD" || ! -d "$AUD" ]] && continue

  # newest files first
  count=0
  while IFS= read -r FILE; do
    parse_aud "$SID" "$FILE" >> "$TMP"
    count=$((count+1))
    [[ $count -ge $MAX_FILES ]] && break
  done < <(find "$AUD" -type f \( -name "*.aud" -o -name "ora_*" -o -name "*.log" \))
done

echo "CSV built → $TMP"

# POST each row to FastAPI
tail -n +2 "$TMP" | while IFS= read -r row; do
  curl -s -X POST "$FASTAPI_URL" \
    -H "Content-Type: application/json" \
    -d "{\"hostname\":\"$HOSTNAME\",\"csv_row\":\"$row\"}" >/dev/null || true
done

echo "Posted to FastAPI → $FASTAPI_URL"
