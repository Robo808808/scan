#!/bin/bash

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
LOG="/tmp/oracle_endpoint_post.log"
DEBUG=1   # set to 0 later after troubleshooting

function debug() {
  [[ "$DEBUG" -eq 1 ]] && echo "[DEBUG] $1"
}

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed" >&2
  exit 1
fi

declare -A ENDPOINTS
declare -A LISTENER_PORTS    # listener_pid => "1521 1522"
declare -A DB_PORTS_MAP      # DB => "1521 1522"

echo ""
echo "===== START DEBUG RUN on host $HOST ====="

###########################################
# STEP 1 — Identify listeners + ports via ss/netstat
###########################################
debug "Discovering running listener processes and ports..."

while read -r PID CMD; do
  debug "Found listener PID $PID ($CMD)"

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

  if [[ -n "$PORTS" ]]; then
    debug " → Listener PID $PID is listening on ports: $PORTS"
    LISTENER_PORTS["$PID"]=$(echo "$PORTS" | sort -u)
  else
    debug " → Listener PID $PID has NO TCP listening ports??"
  fi
done < <(ps -eo pid,args | awk '/tnslsnr/ && !/awk/ && !/grep/ {print $1, $0}')

echo ""

###########################################
# STEP 2 — Loop DBs, detect PMON → Listener FD → ports
###########################################
while IFS=':' read -r DB ORACLE_HOME Y; do
  [[ "$DB" =~ ^# || -z "$DB" ]] && continue

  echo ""
  echo "----- Processing DB: $DB -----"

  PMON_PID=$(pgrep -f "pmon_${DB}")
  if [[ -z "$PMON_PID" ]]; then
    debug "DB $DB is NOT running (no PMON)."
    continue
  fi
  debug "PMON PID for $DB is: $PMON_PID"

  DB_PORTS=()

  # check whether PMON FD table shows connections to listener PIDs
  for L_PID in "${!LISTENER_PORTS[@]}"; do
    debug "Checking whether PMON $PMON_PID has FD connected to listener $L_PID..."

    if ls -l /proc/"$PMON_PID"/fd 2>/dev/null | grep -q "$L_PID"; then
      debug " → PMON has FD referencing listener $L_PID (GOOD)"
      for port in ${LISTENER_PORTS[$L_PID]}; do
        debug "   → Adding port $port for DB $DB"
        DB_PORTS+=("$port")
      done
    else
      debug " → PMON does NOT reference listener $L_PID (ignore)"
    fi
  done

  if [[ ${#DB_PORTS[@]} -eq 0 ]]; then
    debug "!!! DB $DB has NO matched listener ports by FD. It will NOT contribute endpoints."
    continue
  fi

  DB_PORTS_MAP["$DB"]="${DB_PORTS[*]}"

  ###########################################
  # Get CDB root services (filtered)
  ###########################################
  debug "Querying root service names for $DB..."

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

  debug " → Services returned for $DB: ${SERVICES:-NONE}"

  if [[ -z "$SERVICES" ]]; then
    debug "!!! DB $DB found ZERO valid root services — skip"
    continue
  fi

  ###########################################
  # record endpoints to global ENDPOINTS
  ###########################################
  for port in ${DB_PORTS[*]}; do
    for svc in $SERVICES; do
      ep="${HOST}:${port}/${svc}"
      debug "Adding endpoint: $ep"
      ENDPOINTS["$ep"]=1
    done
  done

done < /etc/oratab

echo ""
echo "===== SUMMARY BEFORE JSON ====="
for k in "${!ENDPOINTS[@]}"; do
  echo "  ENDPOINT: $k"
done
echo "================================"
echo ""

###########################################
# STEP 3 — Build JSON
###########################################
PAYLOAD="[]"
for ep in "${!ENDPOINTS[@]}"; do
  PAYLOAD=$(printf '%s\n' "$PAYLOAD" | jq -c --arg ep "$ep" '. += [$ep]')
done

FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

echo "JSON that will be POSTed:"
echo "$FINAL_JSON"
echo ""

curl -s -X POST -H "Content-Type: application/json" -d "$FINAL_JSON" "$API_URL" >/dev/null 2>&1
echo "$FINAL_JSON"
echo ""
echo "===== END DEBUG ====="