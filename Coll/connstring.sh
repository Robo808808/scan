#!/bin/bash

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
LOG="/tmp/oracle_endpoint_post.log"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed" >&2
  exit 1
fi

declare -A ENDPOINTS

###########################################
# Identify listeners + their ports
###########################################
declare -A LISTENER_PORTS  # lsnr_pid -> "1521" etc.

while read -r PID CMD; do
  if command -v ss >/dev/null 2>&1; then
    PORTS=$(ss -ltnp 2>/dev/null | awk -v pid="$PID" '
      $0 ~ "pid=" pid "," {
        split($4,a,":");
        p=a[length(a)];
        if (p ~ /^[0-9]+$/) print p
      }')
  else
    PORTS=$(netstat -ltnp 2>/dev/null | awk -v pid="$PID" '
      $0 ~ "LISTEN" && $0 ~ pid"/" {
        split($4,a,":");
        p=a[length(a)];
        if (p ~ /^[0-9]+$/) print p
      }')
  fi
  [[ -n "$PORTS" ]] && LISTENER_PORTS["$PID"]=$(echo "$PORTS" | sort -u)
done < <(ps -eo pid,args | awk '/tnslsnr/ && !/awk/ && !/grep/ {print $1, $0}')

###########################################
# Loop DBs, match PMON to listener via fd linking
###########################################
while IFS=':' read -r DB ORACLE_HOME Y; do
  [[ "$DB" =~ ^# || -z "$DB" ]] && continue

  PMON_PID=$(pgrep -f "pmon_${DB}")
  [[ -z "$PMON_PID" ]] && continue

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  # Determine which listener ports this DB registered with via FD mapping
  DB_PORTS=()
  for L_PID in "${!LISTENER_PORTS[@]}"; do
    if ls -l /proc/"$PMON_PID"/fd 2>/dev/null | grep -q "$L_PID"; then
      for port in ${LISTENER_PORTS[$L_PID]}; do
        DB_PORTS+=("$port")
      done
    fi
  done

  [[ ${#DB_PORTS[@]} -eq 0 ]] && continue   # Prevent wrong mappings

  # Get root services (con_id 0 or 1)
  SQL_SVC=$(sqlplus -s / as sysdba <<'EOF'
set pages 0 feedback off heading off verify off echo off
SELECT name
FROM v$services
WHERE network_name IS NOT NULL
  AND con_id IN (0,1)
  AND name NOT LIKE '%XDB%'
  AND name NOT LIKE '%_DGMGRL%'
  AND name NOT LIKE '%_CFG'
  AND name NOT LIKE 'SYS$%'
  AND name NOT LIKE 'PDB$SEED%'
ORDER BY name;
EOF
)
  SERVICES=$(printf "%s\n" "$SQL_SVC" | sed '/^$/d')
  [[ -z "$SERVICES" ]] && continue

  for port in "${DB_PORTS[@]}"; do
    for svc in $SERVICES; do
      ENDPOINTS["${HOST}:${port}/${svc}"]=1
    done
  done

done < /etc/oratab

###########################################
# Build JSON + POST
###########################################
PAYLOAD="[]"
for ep in "${!ENDPOINTS[@]}"; do
  PAYLOAD=$(printf '%s\n' "$PAYLOAD" | jq -c --arg ep "$ep" '. += [$ep]')
done

FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

RESP=$(curl -s -o /tmp/endpoint_resp.json -w "%{http_code}" \
  -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "$FINAL_JSON")

echo "$FINAL_JSON"