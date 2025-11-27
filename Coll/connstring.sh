#!/bin/bash

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
LOG="/tmp/oracle_endpoint_post.log"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed" >&2
  exit 1
fi

declare -A ENDPOINTS                # "host:port/service" → 1
declare -A LISTENER_PORTS           # LISTENER -> "1521 1522"

#############################################
# Discover listeners + ports (no DB mapping yet)
#############################################
while read -r PID CMDLINE; do
  LNAME=$(echo "$CMDLINE" | awk '{print $2}')
  [[ -z "$LNAME" ]] && continue

  if command -v ss >/dev/null 2>&1; then
    PORTS=$(ss -ltnp 2>/dev/null | awk -v pid="$PID" '
      $0 ~ "pid=" pid "," {
        split($4,a,":"); p=a[length(a)];
        if (p ~ /^[0-9]+$/) print p;
      }')
  else
    PORTS=$(netstat -ltnp 2>/dev/null | awk -v pid="$PID" '
      $0 ~ "LISTEN" && $0 ~ pid"/" {
        split($4,a,":"); p=a[length(a)];
        if (p ~ /^[0-9]+$/) print p;
      }')
  fi

  [[ -n "$PORTS" ]] && LISTENER_PORTS["$LNAME"]=$(echo "$PORTS" | sort -u)

done < <(ps -eo pid,args | awk '/tnslsnr/ && !/awk/ && !/grep/ {pid=$1; $1=""; print pid, $0}')

#############################################
# Loop DBs and build mapping based on service registration
#############################################
while IFS=':' read -r DB ORACLE_HOME Y; do
  [[ "$DB" =~ ^# || -z "$DB" ]] && continue

  if ! ps -ef | grep -q "[p]mon_${DB}"; then
    continue
  fi

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  ###########################################
  # Get all "public root" services (only root: con_id 1 or 0)
  ###########################################
  SQL_SVC_OUT=$(sqlplus -s / as sysdba <<'EOF'
set pages 0 feedback off heading off verify off echo off
SELECT name
FROM v$services
WHERE network_name IS NOT NULL
  AND con_id IN (0,1)             -- supports your architecture
  AND name NOT LIKE '%XDB%'
  AND name NOT LIKE '%_DGMGRL%'
  AND name NOT LIKE '%_CFG'
  AND name NOT LIKE 'SYS$%'
  AND name NOT LIKE 'PDB$SEED%'
ORDER BY name;
EOF
)
  SERVICES=$(printf "%s\n" "$SQL_SVC_OUT" | sed '/^$/d')
  [[ -z "$SERVICES" ]] && continue

  ###########################################
  # For each *service* the DB reports, find matching listener(s)
  ###########################################
  for svc in $SERVICES; do
    for L in "${!LISTENER_PORTS[@]}"; do
      if lsnrctl status "$L" 2>/dev/null | grep -q "Service \"$svc\""; then
        for port in ${LISTENER_PORTS[$L]}; do
          ENDPOINTS["${HOST}:${port}/${svc}"]=1
        done
      fi
    done
  done

done < /etc/oratab

#############################################
# Build JSON + POST
#############################################
PAYLOAD="[]"
for ep in "${!ENDPOINTS[@]}"; do
  PAYLOAD=$(printf '%s\n' "$PAYLOAD" | jq -c --arg ep "$ep" '. += [$ep]')
done

FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

RESP=$(curl -s -o /tmp/endpoint_resp.json -w "%{http_code}" \
  -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "$FINAL_JSON")

[[ "$RESP" == "200" || "$RESP" == "201" ]] \
  && echo "$(date) OK ($RESP)" >> "$LOG" \
  || echo "$(date) ERROR ($RESP) payload=$FINAL_JSON" >> "$LOG"

echo "$FINAL_JSON"