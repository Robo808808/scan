#!/bin/bash

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
DEBUG=1

log() { [[ $DEBUG -eq 1 ]] && echo "[DEBUG] $1"; }

declare -A ENDPOINTS   # host:port/service → 1

echo "===== START RUN ON $HOST ====="

while IFS=':' read -r DB ORACLE_HOME Y; do
  [[ -z "$DB" || "$DB" =~ ^# ]] && continue

  echo ""
  echo "----- Database: $DB -----"

  # Check DB running
  PMON=$(pgrep -f "pmon_${DB}" || true)
  if [[ -z "$PMON" ]]; then
    log "DB $DB not running – skipping"
    continue
  fi
  log "PMON PID = $PMON"

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  #############################################################
  # 1) Extract LOCAL_LISTENER value
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
  # 2) Extract service names from v$services
  #############################################################
  SVC_RAW=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select name from v\\$services order by name;
EOF
  )
  SERVICES=$(echo "$SVC_RAW" | sed '/^$/d')
  log "Services found:"
  while read -r svc; do log "  - $svc"; done <<< "$SERVICES"

  if [[ -z "$SERVICES" ]]; then
    log "No services for DB – skipping"
    continue
  fi

  #############################################################
  # 3) Work out the listener process + port based on LOCAL_LISTENER
  #############################################################

  PORT=""
  LSN_PID=""

  # If LOCAL_LISTENER contains PORT=
  if [[ "$LL" =~ PORT[=)]([0-9]+) ]]; then
    PORT="${BASH_REMATCH[1]}"
    log "Extracted PORT from LOCAL_LISTENER → $PORT"
  else
    # Otherwise LOCAL_LISTENER contains a listener name (e.g., LISTENER_DB1)
    LIST_NAME=$(echo "$LL" | sed "s/(.*//" | sed 's/ .*//')
    log "Treating LOCAL_LISTENER as listener name: $LIST_NAME"

    # Get listener PID
    LSN_PID=$(ps -eo pid,args | awk -v pat="$LIST_NAME" '/tnslsnr/ && $0 ~ pat {print $1}' | head -n 1)
    log "Listener PID guess: $LSN_PID"

    if [[ -n "$LSN_PID" ]]; then
      if command -v ss >/dev/null 2>&1; then
        PORT=$(ss -ltnp | awk -v pid="$LSN_PID" '$0 ~ "pid=" pid "," {
          split($4,a,":"); print a[length(a)]
        }' | head -n 1)
      else
        PORT=$(netstat -ltnp | awk -v pid="$LSN_PID" '$0 ~ pid"/" {
          split($4,a,":"); print a[length(a)]
        }' | head -n 1)
      fi
      log "Discovered port from PID=$LSN_PID → $PORT"
    fi
  fi

  if [[ -z "$PORT" ]]; then
    log "Could not determine listener PORT – skipping DB"
    continue
  fi

  #############################################################
  # Combine host:port/service
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
echo "----- Final JSON -----"
echo "$FINAL_JSON"

# POST (optional)
# curl -s -X POST -H "Content-Type: application/json" -d "$FINAL_JSON" "$API_URL"