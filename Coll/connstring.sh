#!/bin/bash

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
DEBUG=1
log() { [[ $DEBUG -eq 1 ]] && echo "[DEBUG] $1"; }

declare -A ENDPOINTS

echo "===== START RUN ON $HOST ====="

while IFS=':' read -r DB ORACLE_HOME Y; do
  [[ -z "$DB" || "$DB" =~ ^# ]] && continue

  echo ""
  echo "----- Database: $DB -----"

  PMON=$(pgrep -f "pmon_${DB}" || true)
  if [[ -z "$PMON" ]]; then
    log "DB $DB not running – skipping"
    continue
  fi

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  #############################################################
  # 1) LOCAL_LISTENER
  #############################################################
  LL=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select value from v\\$parameter where name='local_listener';
EOF
  )
  LL=$(echo "$LL" | xargs)
  log "LOCAL_LISTENER = '$LL'"

  if [[ -z "$LL" ]]; then
    log "No LOCAL_LISTENER – skipping DB"
    continue
  fi

  #############################################################
  # 2) Get service names for this DB
  #############################################################
  SVC_RAW=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select name from v\\$services order by name;
EOF
  )
  SERVICES=$(echo "$SVC_RAW" | sed '/^$/d')

  if [[ -z "$SERVICES" ]]; then
    log "No services for DB – skipping"
    continue
  fi

  log "Services:"
  while read -r svc; do log "  - $svc"; done <<< "$SERVICES"

  #############################################################
  # 3) Derive listener port
  #############################################################

  PORT=""
  LSN_PID=""

  # Case 1: LOCAL_LISTENER contains an explicit PORT
  if [[ "$LL" =~ PORT=([0-9]+) ]]; then
    PORT="${BASH_REMATCH[1]}"
    log "Extracted PORT from LOCAL_LISTENER → $PORT"
  else
    # Case 2: LOCAL_LISTENER is a listener name (e.g., LISTENER_DB1)
    LIST_NAME=$(echo "$LL" | sed 's/(.*//; s/ .*//')
    log "Treating LOCAL_LISTENER as listener name: $LIST_NAME"

    LSN_PID=$(ps -eo pid,args | awk -v pat="$LIST_NAME" '/tnslsnr/ && $0 ~ pat {print $1}' | head -n 1)
    log "Listener PID guess: $LSN_PID"

    if [[ -n "$LSN_PID" ]]; then
      if command -v ss >/dev/null 2>&1; then
        PORT=$(ss -ltnp | awk -v pid="$LSN_PID" '$0 ~ "pid=" pid "," {split($4,a,":"); print a[length(a)]}' | head -n 1)
      else
        PORT=$(netstat -ltnp | awk -v pid="$LSN_PID" '$0 ~ pid"/" {split($4,a,":"); print a[length(a)]}' | head -n 1)
      fi
      log "Discovered port from PID=$LSN_PID → $PORT"
    fi
  fi

  if [[ -z "$PORT" ]]; then
    log "Could not determine listener PORT – skipping DB"
    continue
  fi

  #############################################################
  # Create endpoints for this DB
  #############################################################
  for svc in $SERVICES; do
    EP="${HOST}:${PORT}/${svc}"
    log "Adding endpoint → $EP"
    ENDPOINTS["$EP"]=1
  done

done < /etc/oratab

#############################################################
# Build JSON
#############################################################
PAYLOAD="[]"
for ep in "${!ENDPOINTS[@]}"; do
  PAYLOAD=$(printf '%s' "$PAYLOAD" | jq --arg ep "$ep" '. += [$ep]')
done

FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

echo "----- Final JSON Payload -----"
echo "$FINAL_JSON"
echo "===== END RUN ====="

# POST (optional):
# curl -s -X POST -H "Content-Type: application/json" -d "$FINAL_JSON" "$API_URL"