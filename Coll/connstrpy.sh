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
select value from v$parameter where name='local_listener';
EOF
  )
  LL=$(echo "$LL" | xargs)
  log "LOCAL_LISTENER = '$LL'"

  #################################################################
  # 2) Services
  #################################################################
  SVC_RAW=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select name from v$services order by name;
EOF
  )
  SERVICES=$(echo "$SVC_RAW" | sed '/^$/d')

  if [[ -z "$SERVICES" ]]; then
    log "No services returned — skipping"
    continue
  fi

  #################################################################
  # 3) Determine PORT
  #################################################################
  PORT=""

  # Case A1 — contains PORT=
  if [[ "$LL" =~ PORT=([0-9]+) ]]; then
    PORT="${BASH_REMATCH[1]}"
    log "Extracted PORT from LOCAL_LISTENER descriptor: $PORT"

  # Case A2 — hostname:port
  elif [[ "$LL" =~ :([0-9]+)$ ]]; then
    PORT="${BASH_REMATCH[1]}"
    log "Extracted PORT from host:port: $PORT"

  fi

  # If still no port → alias lookup
  if [[ -z "$PORT" ]]; then
    LNAME="$LL"
    [[ -z "$LNAME" ]] && LNAME="LISTENER"   # default if NULL
    log "Using alias for lookup: $LNAME"

    LSN_PID=$(ps -ef | grep -i tnslsnr | grep -i "$LNAME" | grep -v grep | awk '{print $2}' | head -n 1)
    log "Alias '$LNAME' resolved to PID = $LSN_PID"

    if [[ -z "$LSN_PID" ]]; then
      log "Listener alias not found — skipping DB"
      continue
    fi

    if command -v ss >/dev/null 2>&1; then
      PORT=$(ss -ltnp | awk -v pid="$LSN_PID" \
        '$0 ~ "pid=" pid "," {split($4,a,":"); print a[length(a)]}' | head -n 1)
    else
      PORT=$(netstat -ltnp | awk -v pid="$LSN_PID" \
        '$0 ~ pid"/" {split($4,a,":"); print a[length(a)]}' | head -n 1)
    fi

    log "PID $LSN_PID listened on PORT $PORT"
  fi

  if [[ -z "$PORT" ]]; then
    log "Cannot determine listener port — skipping DB"
    continue
  fi

  #################################################################
  # 4) Add endpoints
  #################################################################
  for svc in $SERVICES; do
    EP="${HOST}:${PORT}/${svc}"
    log "Adding endpoint → $EP"
    ENDPOINTS["$EP"]=1
  done

done < /etc/oratab


#################################################################
# 5) Build JSON using Python (no jq needed)
#################################################################
# Build a | delimited string of endpoints: "x|y|z"
ENDPOINT_LIST=""
for ep in "${!ENDPOINTS[@]}"; do
  ENDPOINT_LIST="${ENDPOINT_LIST:+$ENDPOINT_LIST|}$ep"
done

FINAL_JSON=$(HOSTNAME="$HOST" ENDPOINTS="$ENDPOINT_LIST" python3 - <<'EOF'
import json, os
host = os.environ["HOSTNAME"]
raw  = os.environ.get("ENDPOINTS", "")
arr  = raw.split("|") if raw else []
print(json.dumps({host: arr}))
EOF
)

echo ""
echo "===== FINAL JSON ====="
echo "$FINAL_JSON"
echo "===== END RUN ====="
