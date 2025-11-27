#!/bin/bash

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
LOG="/tmp/oracle_endpoint_post.log"
TMP="/tmp/oracle_root_services.$$"
> "$TMP"

#############################################
# 1. Discover running listener processes
#############################################
LISTENERS=()

# Find LSNR processes & extract listener name
for p in $(ps -eo args | grep -i "tnslsnr" | grep -v grep); do
  lname=$(echo "$p" | awk '{print $2}')
  [[ -n "$lname" ]] && LISTENERS+=("$lname")
done

# Deduplicate
LISTENERS=($(printf "%s\n" "${LISTENERS[@]}" | sort -u))

# Map: listener_name : host:port list
declare -A LISTENER_MAP

for L in "${LISTENERS[@]}"; do
  # Parse host/port from lsnrctl status
  OUT=$(lsnrctl status "$L" 2>/dev/null)
  HP=$(echo "$OUT" | awk '
    /ADDRESS=/ {
      if (match($0,/HOST=([^)]*)/,h) && match($0,/PORT=([0-9]*)/,p))
        print h[1] ":" p[1]
    }' | sort -u)

  if [[ -n "$HP" ]]; then
    LISTENER_MAP["$L"]="$HP"
  fi
done

#############################################
# 2. Loop through databases in /etc/oratab
#############################################
while IFS=':' read -r DB ORACLE_HOME Y; do
  [[ "$DB" =~ ^# || -z "$DB" ]] && continue

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  # Check DB is running
  if ! ps -ef | grep -q "[p]mon_$DB"; then
    echo "$(date) Skipping $DB (not running)" >> "$LOG"
    continue
  fi

  # Query root-only services, fallback for non-CDB
  SQL_OUT=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off verify off echo off
WITH svc AS (
  SELECT name, con_id
  FROM v\\$services
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

  ROOT_SERVICES=$(echo "$SQL_OUT" | sed '/^$/d')
  [[ -z "$ROOT_SERVICES" ]] && continue

  # For each listener, add endpoints
  for lname in "${!LISTENER_MAP[@]}"; do
    for hp in ${LISTENER_MAP[$lname]}; do
      for svc in $ROOT_SERVICES; do
        echo "${hp}/${svc}" >> "$TMP"
      done
    done
  done

done < /etc/oratab

#############################################
# 3. Build JSON payload
#############################################
PAYLOAD="[]"
while read -r ep; do
  [[ -z "$ep" ]] && continue
  PAYLOAD=$(echo "$PAYLOAD" | jq -c --arg ep "$ep" '. += [$ep]')
done < "$TMP"

FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

#############################################
# 4. POST to FastAPI
#############################################
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
rm -f "$TMP"
