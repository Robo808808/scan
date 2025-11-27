#!/bin/bash
#
# Discover Oracle root-container (or non-CDB) services and POST them
# as hostname:port/service to a central FastAPI collector.
#

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
LOG="/tmp/oracle_endpoint_post.log"

# Require jq
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found in PATH" >&2
  exit 1
fi

#############################################
# 1. Discover ports used by running TNSLSNR
#############################################

declare -A PORTS_MAP   # unique list of ports: PORTS_MAP[1521]=1 etc.

# Get all tnslsnr PIDs
while read -r PID CMDLINE; do
  # Find listening TCP ports for this PID using ss or netstat
  if command -v ss >/dev/null 2>&1; then
    PORTS=$(ss -ltnp 2>/dev/null | awk -v pid="$PID" '
      $0 ~ "pid=" pid "," {
        # local address:port is col 4
        split($4, a, ":");
        port=a[length(a)];
        if (port ~ /^[0-9]+$/) print port;
      }' | sort -u)
  else
    # Fallback to netstat
    PORTS=$(netstat -ltnp 2>/dev/null | awk -v pid="$PID" '
      $0 ~ "LISTEN" && $0 ~ pid"/" {
        split($4, a, ":");
        port=a[length(a)];
        if (port ~ /^[0-9]+$/) print port;
      }' | sort -u)
  fi

  for p in $PORTS; do
    PORTS_MAP["$p"]=1
  done

done < <(ps -eo pid,args | awk '/tnslsnr/ && !/awk/ && !/grep/ {pid=$1; $1=""; sub(/^ /,"",$0); print pid, $0}')

if [[ ${#PORTS_MAP[@]} -eq 0 ]]; then
  echo "$(date) No listener ports discovered on $HOST" >> "$LOG"
fi

#############################################
# 2. Loop DBs in /etc/oratab and collect services
#############################################

declare -A EP_MAP   # unique endpoints: EP_MAP["host:port/service"]=1

while IFS=':' read -r DB ORACLE_HOME Y; do
  # Skip comments/blank
  [[ "$DB" =~ ^# || -z "$DB" ]] && continue

  # Only consider DB entries (not ASM, etc.) – optional filter
  # [[ "$DB" == *"+"* ]] && continue

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  # Check DB is running via PMON
  if ! ps -ef | grep -q "[p]mon_${DB}"; then
    echo "$(date) Skipping $DB (PMON not running)" >> "$LOG"
    continue
  fi

  # Run SQL to get root-only services; fallback for non-CDB
  SQL_OUT=$(sqlplus -s / as sysdba <<'EOF'
set pages 0 feedback off heading off verify off echo off
WITH svc AS (
  SELECT name, con_id
  FROM v$services
  WHERE network_name IS NOT NULL
),
root_svc AS (
  SELECT name FROM svc WHERE con_id = 0
),
fallback AS (
  SELECT name FROM svc
)
SELECT name FROM root_svc
UNION
SELECT name FROM fallback WHERE NOT EXISTS (SELECT 1 FROM root_svc);
EOF
)

  # Normalise / strip empty
  ROOT_SERVICES=$(printf "%s\n" "$SQL_OUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')

  if [[ -z "$ROOT_SERVICES" ]]; then
    echo "$(date) No services returned for $DB on $HOST" >> "$LOG"
    continue
  fi

  # For this DB, combine each discovered port with each root service
  for port in "${!PORTS_MAP[@]}"; do
    for svc in $ROOT_SERVICES; do
      ep="${HOST}:${port}/${svc}"
      EP_MAP["$ep"]=1
    done
  done

done < /etc/oratab

#############################################
# 3. Build JSON payload (per host)
#############################################

PAYLOAD="[]"

for ep in "${!EP_MAP[@]}"; do
  PAYLOAD=$(printf '%s\n' "$PAYLOAD" | jq -c --arg ep "$ep" '. += [$ep]')
done

# If nothing found, still send empty list for the host
FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

#############################################
# 4. POST to FastAPI
#############################################

RESP=$(curl -s -o /tmp/endpoint_resp.json -w "%{http_code}" \
  -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "$FINAL_JSON")

if [[ "$RESP" == "200" || "$RESP" == "201" ]]; then
  echo "$(date) OK posted endpoints for $HOST ($RESP)" >> "$LOG"
else
  echo "$(date) ERROR posting endpoints for $HOST code=$RESP payload=$FINAL_JSON" >> "$LOG"
fi

echo "$FINAL_JSON"