#!/bin/bash

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
LOG="/tmp/oracle_endpoint_post.log"
DEBUG=1   # set to 0 later to quiet it down

log_debug() {
  if [[ "$DEBUG" -eq 1 ]]; then
    echo "[DEBUG] $1"
  fi
}

echo "===== START DEBUG RUN on host $HOST ====="

# Check jq up front
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed in PATH" >&2
  exit 1
fi

declare -A ENDPOINTS         # "host:port/service" -> 1
declare -A LISTENER_PORTS    # listener_pid -> "1521 1522"

###########################################
# STEP 1: Discover listeners + their ports
###########################################
log_debug "Discovering listener processes (tnslsnr) and ports..."

while read -r PID CMD; do
  log_debug "  Listener candidate PID=$PID CMD=$CMD"

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
    PORTS_SORTED=$(echo "$PORTS" | sort -u | xargs)
    log_debug "    -> Listener PID=$PID ports: $PORTS_SORTED"
    LISTENER_PORTS["$PID"]="$PORTS_SORTED"
  else
    log_debug "    -> Listener PID=$PID has NO listening TCP ports (unexpected)"
  fi

done < <(ps -eo pid,args | awk '/tnslsnr/ && !/awk/ && !/grep/ {print $1, $0}')

if [[ ${#LISTENER_PORTS[@]} -eq 0 ]]; then
  log_debug "No tnslsnr processes found on this host."
fi

###########################################
# STEP 2: Loop DBs in /etc/oratab, PMON -> listener FD -> ports
###########################################
while IFS=':' read -r DB ORACLE_HOME Y; do
  [[ "$DB" =~ ^# || -z "$DB" ]] && continue

  echo ""
  echo "----- Processing DB: $DB -----"

  # find PMON
  PMON_PID=$(pgrep -f "pmon_${DB}" || true)
  if [[ -z "$PMON_PID" ]]; then
    log_debug "  DB $DB: no PMON found (DB down?) - skipping"
    continue
  fi
  log_debug "  DB $DB: PMON PID=$PMON_PID"

  # ensure /proc entry exists
  if [[ ! -d "/proc/$PMON_PID/fd" ]]; then
    log_debug "  DB $DB: /proc/$PMON_PID/fd does not exist - skipping"
    continue
  fi

  # figure out which listener PIDs this PMON references
  DB_PORTS=()

  for L_PID in "${!LISTENER_PORTS[@]}"; do
    log_debug "    Checking FDs of PMON $PMON_PID for listener PID $L_PID"

    # show a small sample of fd lines to understand what's in there (first 5)
    if [[ "$DEBUG" -eq 1 ]]; then
      log_debug "      Sample of /proc/$PMON_PID/fd (first 5 lines):"
      ls -l "/proc/$PMON_PID/fd" 2>/dev/null | head -n 5 | sed 's/^/        /'
    fi

    # This is the controversial step: grep for L_PID in the FD listing
    if ls -l "/proc/$PMON_PID/fd" 2>/dev/null | grep -q "$L_PID"; then
      log_debug "      -> MATCH: PMON $PMON_PID appears to reference listener PID $L_PID"
      for port in ${LISTENER_PORTS[$L_PID]}; do
        log_debug "         -> associating port $port with DB $DB (via listener PID $L_PID)"
        DB_PORTS+=("$port")
      done
    else
      log_debug "      -> NO MATCH: PMON $PMON_PID does not reference listener PID $L_PID"
    fi
  done

  if [[ ${#DB_PORTS[@]} -eq 0 ]]; then
    log_debug "  DB $DB: NO ports associated via FD mapping. This DB will NOT contribute endpoints."
    continue
  else
    log_debug "  DB $DB: collected ports: ${DB_PORTS[*]}"
  fi

  ###########################################
  # STEP 2b: get root 'public' services
  ###########################################
  log_debug "  DB $DB: querying filtered root services (v\$services)..."

  SQL_SVC_OUT=$(sqlplus -s / as sysdba <<'EOF'
set pages 0 feedback off heading off verify off echo off termout on
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
  SQL_STATUS=$?

  if [[ $SQL_STATUS -ne 0 ]]; then
    log_debug "  DB $DB: sqlplus exited with status $SQL_STATUS"
    log_debug "  DB $DB: raw SQL output was:"
    echo "$SQL_SVC_OUT" | sed 's/^/    [SQL]/'
    continue
  fi

  # NOTE: if there are ORA-/SP2- errors they’ll also appear here
  if echo "$SQL_SVC_OUT" | grep -qE 'ORA-|SP2-'; then
    log_debug "  DB $DB: v\$services query returned ORA-/SP2- errors, skipping this DB"
    echo "$SQL_SVC_OUT" | sed 's/^/    [SQLERR]/'
    continue
  fi

  SERVICES=$(printf "%s\n" "$SQL_SVC_OUT" | sed '/^$/d')

  if [[ -z "$SERVICES" ]]; then
    log_debug "  DB $DB: v\$services query returned NO services after filtering."
    continue
  else
    log_debug "  DB $DB: services to publish:"
    printf "%s\n" "$SERVICES" | sed 's/^/    svc: /'
  fi

  ###########################################
  # STEP 2c: add endpoints for this DB
  ###########################################
  for port in "${DB_PORTS[@]}"; do
    for svc in $SERVICES; do
      ep="${HOST}:${port}/${svc}"
      log_debug "  DB $DB: adding endpoint $ep"
      ENDPOINTS["$ep"]=1
    done
  done

done < /etc/oratab

###########################################
# STEP 3: show summary BEFORE building JSON
###########################################
echo ""
echo "===== SUMMARY BEFORE JSON ====="
if [[ ${#ENDPOINTS[@]} -eq 0 ]]; then
  echo "  (no endpoints discovered)"
else
  for ep in "${!ENDPOINTS[@]}"; do
    echo "  ENDPOINT: $ep"
  done
fi
echo "================================"
echo ""

###########################################
# STEP 4: Build JSON payload safely
###########################################
PAYLOAD='[]'   # start as valid JSON array

for ep in "${!ENDPOINTS[@]}"; do
  # if jq fails, log and bail out (prevents payload becoming garbage)
  NEW_PAYLOAD=$(printf '%s\n' "$PAYLOAD" | jq -c --arg ep "$ep" '. += [$ep]' 2>/tmp/jq_error.$$.log || echo "")
  if [[ -z "$NEW_PAYLOAD" ]]; then
    echo "ERROR: jq failed while adding endpoint '$ep'" >&2
    echo "jq stderr:" >&2
    sed 's/^/  /' /tmp/jq_error.$$.log >&2
    rm -f /tmp/jq_error.$$.log
    exit 1
  fi
  rm -f /tmp/jq_error.$$.log
  PAYLOAD="$NEW_PAYLOAD"
done

log_debug "Final PAYLOAD JSON array: $PAYLOAD"

# Wrap in outer object { "host": [ ... ] }
FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')
log_debug "FINAL_JSON to POST:"
log_debug "$FINAL_JSON"

###########################################
# STEP 5: POST
###########################################
RESP=$(curl -s -o /tmp/endpoint_resp.json -w "%{http_code}" \
  -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "$FINAL_JSON")

echo "HTTP response code from API: $RESP"
echo "JSON sent:"
echo "$FINAL_JSON"
echo "===== END DEBUG RUN ====="
