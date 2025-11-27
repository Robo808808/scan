#!/bin/bash
#
# Discover Oracle "public" CDB root services per database and POST
# them to a FastAPI collector in JSON form: { "hostname": [ "host:port/service" ] }
#

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
LOG="/tmp/oracle_endpoint_post.log"

# Require jq
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found in PATH" >&2
  exit 1
fi

declare -A DB_ENDPOINTS  # map of "host:port/service" unique

#############################################
# STEP 1 — Identify listeners with ports AND their DB instances
#############################################

declare -A LISTENER_PORTS
declare -A LISTENER_INSTANCES   # LISTENER_INSTANCES["LISTENER1"]="db1 db2"

while read -r PID CMDLINE; do
  LNAME=$(echo "$CMDLINE" | awk '{print $2}')
  [[ -z "$LNAME" ]] && continue

  # Find ports
  if command -v ss >/dev/null 2>&1; then
    PORTS=$(ss -ltnp 2>/dev/null | awk -v pid="$PID" '
      $0 ~ "pid=" pid "," {
        split($4,a,":"); port=a[length(a)];
        if (port ~ /^[0-9]+$/) print port;
      }')
  else
    PORTS=$(netstat -ltnp 2>/dev/null | awk -v pid="$PID" '
      $0 ~ "LISTEN" && $0 ~ pid"/" {
        split($4,a,":"); port=a[length(a)];
        if (port ~ /^[0-9]+$/) print port;
      }')
  fi
  [[ -n "$PORTS" ]] && LISTENER_PORTS["$LNAME"]=$(echo "$PORTS" | sort -u)

  # Parse DB instances registered with this listener
  STATUS=$(lsnrctl status "$LNAME" 2>/dev/null)
  INSTS=$(echo "$STATUS" | awk '
    /Instance "/ {
      gsub(/"/,"",$2);
      inst=$2
      print inst
    }')
  [[ -n "$INSTS" ]] && LISTENER_INSTANCES["$LNAME"]=$(echo "$INSTS" | sort -u)

done < <(ps -eo pid,args | awk '/tnslsnr/ && !/awk/ && !/grep/ {pid=$1; $1=""; print pid, $0}')

#############################################
# STEP 2 — Loop /etc/oratab & link DB to its listener ports
#############################################

while IFS=':' read -r DB ORACLE_HOME Y; do
  [[ "$DB" =~ ^# || -z "$DB" ]] && continue

  # Check PMON running → DB is up
  if ! ps -ef | grep -q "[p]mon_${DB}"; then
    echo "$(date) DB $DB not running — skipping" >> "$LOG"
    continue
  fi

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  # Determine which listener(s) serve this DB
  DB_LISTENER_PORTS=()
  for L in "${!LISTENER_INSTANCES[@]}"; do
    for inst in ${LISTENER_INSTANCES[$L]}; do
      [[ "$inst" == "$DB" ]] || continue
      for port in ${LISTENER_PORTS[$L]}; do
        DB_LISTENER_PORTS+=("$port")
      done
    done
  done

  # If no listener claims the DB → fallback = all listener ports?
  if [[ ${#DB_LISTENER_PORTS[@]} -eq 0 ]]; then
    for L in "${!LISTENER_PORTS[@]}"; do
      for port in ${LISTENER_PORTS[$L]}; do
        DB_LISTENER_PORTS+=("$port")
      done
    done
  fi

  # Get filtered root-container services (all of them, not just one)
  SQL_OUT=$(sqlplus -s / as sysdba <<'EOF'
set pages 0 feedback off heading off verify off echo off
SELECT name
FROM v$services
WHERE network_name IS NOT NULL
  AND con_id = 0
  AND name NOT LIKE '%XDB%'
  AND name NOT LIKE '%_DGMGRL%'
  AND name NOT LIKE '%_CFG'
  AND name NOT LIKE 'SYS$%'
  AND name NOT LIKE 'PDB$SEED%'
ORDER BY name;
EOF
  )

  SERVICES=$(printf "%s\n" "$SQL_OUT" | sed '/^$/d')
  [[ -z "$SERVICES" ]] && continue

  # Combine DB-matching listener ports + all (filtered) services
  for port in "${DB_LISTENER_PORTS[@]}"; do
    for svc in $SERVICES; do
      ep="${HOST}:${port}/${svc}"
      DB_ENDPOINTS["$ep"]=1
    done
  done

done < /etc/oratab

#############################################
# STEP 3 — Build JSON + POST
#############################################

PAYLOAD="[]"
for ep in "${!DB_ENDPOINTS[@]}"; do
  PAYLOAD=$(printf '%s\n' "$PAYLOAD" | jq -c --arg ep "$ep" '. += [$ep]')
done

FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

RESP=$(curl -s -o /tmp/endpoint_resp.json -w "%{http_code}" \
  -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "$FINAL_JSON")

if [[ "$RESP" == "200" || "$RESP" == "201" ]]; then
  echo "$(date) OK posted for $HOST ($RESP)" >> "$LOG"
else
  echo "$(date) ERROR posting for $HOST code=$RESP payload=$FINAL_JSON" >> "$LOG"
fi

echo "$FINAL_JSON"
