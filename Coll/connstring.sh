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
  # 1) LOCAL_LISTENER
  #################################################################
  LL=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select value from v\$parameter where name='local_listener';
EOF
  )
  LL=$(echo "$LL" | xargs) # trim whitespace
  log "LOCAL_LISTENER raw = '$LL'"

  # CASE C — if LOCAL_LISTENER is NULL
  if [[ -z "$LL" ]]; then
    LNAME="LISTENER"    # Oracle default
    log "LOCAL_LISTENER is NULL — assuming default listener name '$LNAME'"
  fi

  #################################################################
  # 2) Services (unfiltered)
  #################################################################
  SVC_RAW=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select name from v\$services order by name;
EOF
  )
  SERVICES=$(echo "$SVC_RAW" | sed '/^$/d')
  if [[ -z "$SERVICES" ]]; then
    log "No services returned — skipping"
    continue
  fi

  log "Services:"
  while read -r svc; do log "  - $svc"; done <<< "$SERVICES"

  #################################################################
  # 3) Determine PORT
  #################################################################
  PORT=""
  LSN_PID=""

  if [[ -n "$LL" ]]; then

    ###############################################################
    # Case A1 — TNS connect descriptor with PORT=
    ###############################################################
    if [[ "$LL" =~ PORT=([0-9]+) ]]; then
      PORT="${BASH_REMATCH[1]}"
      log "LOCAL_LISTENER contains TNS descriptor — extracted PORT $PORT"

    ###############################################################
    # Case A2 — hostname:port format
    ###############################################################
    elif [[ "$LL" =~ :([0-9]+)$ ]]; then
      PORT="${BASH_REMATCH[1]}"
      log "LOCAL_LISTENER is host:port — extracted PORT $PORT"

    ###############################################################
    # Case B — listener alias (tnsnames style)
    ###############################################################
    else
      LNAME="$LL"
      log "LOCAL_LISTENER appears to be alias '$LNAME'"
    fi
  fi

  #################################################################
  # If port is still empty → listener alias lookup
  #################################################################
  if [[ -z "$PORT" ]]; then
    log "Attempting PID discovery for listener alias '$LNAME'"

    LSN_PID=$(ps -ef | grep -i tnslsnr | grep -i "$LNAME" | grep -v grep | awk '{print $2}' | head -n 1)
    log "Listener alias '$LNAME' → PID = $LSN_PID"

    if [[ -z "$LSN_PID" ]]; then
      log "Listener alias '$LNAME' not found — skipping DB"
      continue
    fi

    if command -v ss >/dev/null 2>&1; then
      PORT=$(ss -ltnp | awk -v pid="$LSN_PID" '$0 ~ "pid=" pid "," {split($4,a,":"); print a[length(a)]}' | head -n 1)
    else
      PORT=$(netstat -ltnp | awk -v pid="$LSN_PID" '$0 ~ pid"/" {split($4,a,":"); print a[length(a)]}' | head -n 1)
    fi

    log "Listener PID $LSN_PID → PORT $PORT"
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
# 5) Build JSON
#################################################################
PAYLOAD="[]"
for ep in "${!ENDPOINTS[@]}"; do
  PAYLOAD=$(printf '%s' "$PAYLOAD" | jq --arg ep "$ep" '. += [$ep]')
done

FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

echo ""
echo "===== FINAL JSON ====="
echo "$FINAL_JSON"
echo "===== END RUN ====="
