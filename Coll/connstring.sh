#!/bin/bash

HOST=$(hostname -s)
DEBUG=1
log() { [[ $DEBUG -eq 1 ]] && echo "[DEBUG] $1"; }

declare -A ENDPOINTS

echo "===== START RUN ON $HOST ====="

while IFS=':' read -r DB ORACLE_HOME Y; do
  [[ -z "$DB" || "$DB" =~ ^# ]] && continue

  echo ""
  echo "----- Processing DB: $DB -----"

  PMON=$(pgrep -f "pmon_${DB}" || true)
  if [[ -z "$PMON" ]]; then
    log "DB $DB not running — skipping"
    continue
  fi

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  #################################################################
  # 1) Read LOCAL_LISTENER
  #################################################################
  LL=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select value from v\\$parameter where name='local_listener';
EOF
  )
  LL=$(echo "$LL" | xargs)
  log "LOCAL_LISTENER = '$LL'"

  if [[ -z "$LL" ]]; then
    log "No LOCAL_LISTENER — skipping"
    continue
  fi

  #################################################################
  # 2) Extract services
  #################################################################
  SVC_RAW=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select name from v\\$services order by name;
EOF
  )
  SERVICES=$(echo "$SVC_RAW" | sed '/^$/d')
  if [[ -z "$SERVICES" ]]; then
    log "No services returned — skipping"
    continue
  fi

  #################################################################
  # 3) Determine PORT from LOCAL_LISTENER
  #################################################################
  PORT=""

  ## Case A: LOCAL_LISTENER includes explicit PORT=
  if [[ "$LL" =~ PORT=([0-9]+) ]]; then
    PORT="${BASH_REMATCH[1]}"
    log "Extracted port directly from LOCAL_LISTENER → $PORT"

  ## Case B: LOCAL_LISTENER is a TNS alias e.g. LISTENER_DB1
  else
    LNAME="$LL"
    log "LOCAL_LISTENER appears to be listener alias → $LNAME"

    # Find listener PID based on command line matching the alias
    LPID=$(ps -eo pid,args | awk -v ln="$LNAME" '/tnslsnr/ && $0 ~ ln {print $1}' | head -n 1)

    if [[ -z "$LPID" ]]; then
      log "Listener alias '$LNAME' not found in running processes — skipping DB"
      continue
    fi
    log "Listener alias '$LNAME' corresponds to PID $LPID"

    # Derive port from listener PID via ss/netstat
    if command -v ss >/dev/null 2>&1; then
      PORT=$(ss -ltnp | awk -v pid="$LPID" '$0 ~ "pid=" pid "," {split($4,a,":"); print a[length(a)]}' | head -n 1)
    else
      PORT=$(netstat -ltnp | awk -v pid="$LPID" '$0 ~ pid"/" {split($4,a,":"); print a[length(a)]}' | head -n 1)
    fi

    log "Listener PID $LPID → PORT $PORT"
  fi

  if [[ -z "$PORT" ]]; then
    log "Could not determine port — skipping DB"
    continue
  fi

  #################################################################
  # 4) Build endpoint(s)
  #################################################################
  for svc in $SERVICES; do
    EP="${HOST}:${PORT}/${svc}"
    log "Adding endpoint $EP"
    ENDPOINTS["$EP"]=1
  done

done < /etc/oratab


#################################################################
# 5) Build JSON payload
#################################################################
PAYLOAD="[]"
for ep in "${!ENDPOINTS[@]}"; do
  PAYLOAD=$(printf '%s' "$PAYLOAD" | jq --arg ep "$ep" '. += [$ep]')
done

FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

echo ""
echo "===== FINAL JSON ====="
echo "$FINAL_JSON"