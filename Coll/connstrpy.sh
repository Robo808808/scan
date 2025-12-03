#!/bin/bash

HOST=$(hostname -s)
DEBUG=1
log() { [ "$DEBUG" -eq 1 ] && echo "[DEBUG] $1"; }

declare -A ENDPOINTS

echo "===== START RUN ON $HOST ====="

###########################################################
# Loop through DBs in /etc/oratab
###########################################################
while IFS=':' read -r DB ORACLE_HOME Y; do
  [ -z "$DB" ] && continue
  case "$DB" in \#*) continue ;; esac

  echo ""
  echo "----- Processing DB: $DB -----"

  PMON=$(pgrep -f "pmon_${DB}" || true)
  if [ -z "$PMON" ]; then
    log "DB $DB: PMON not running — skipping"
    continue
  fi
  log "DB $DB: PMON PID = $PMON"

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  ###########################################################
  # 1) Read LOCAL_LISTENER
  ###########################################################
  LL=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select value from v$parameter where name='local_listener';
EOF
)
  LL=$(echo "$LL" | xargs)  # trim whitespace
  log "DB $DB: LOCAL_LISTENER = '$LL'"

  ###########################################################
  # 2) Get service names
  ###########################################################
  SVC_RAW=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select name from v$services order by name;
EOF
)
  SERVICES=$(echo "$SVC_RAW" | sed '/^$/d')
  if [ -z "$SERVICES" ]; then
    log "DB $DB: no services — skipping"
    continue
  fi

  ###########################################################
  # 3) Determine listener port
  ###########################################################
  PORT=""
  LNAME=""

  # Case A1: LOCAL_LISTENER contains PORT=NNNN
  if echo "$LL" | grep -q 'PORT='; then
    PORT=$(echo "$LL" | sed -n 's/.*PORT=\([0-9][0-9]*\).*/\1/p' | head -n 1)
    log "DB $DB: extracted PORT from descriptor → $PORT"

  # Case A2: LOCAL_LISTENER looks like host:port
  elif echo "$LL" | grep -q ':'; then
    # Last colon segment; then ensure it’s numeric
    PORT_CAND=${LL##*:}
    if echo "$PORT_CAND" | grep -Eq '^[0-9]+$'; then
      PORT="$PORT_CAND"
      log "DB $DB: extracted PORT from host:port → $PORT"
    else
      log "DB $DB: host:port pattern but tail not numeric ('$PORT_CAND')"
    fi
  fi

  # Case B: alias (or NULL → LISTENER)
  if [ -z "$PORT" ]; then
    if [ -z "$LL" ]; then
      LNAME="LISTENER"
      log "DB $DB: LOCAL_LISTENER NULL — defaulting alias '$LNAME'"
    else
      LNAME="$LL"
      log "DB $DB: treating LOCAL_LISTENER as alias '$LNAME'"
    fi

    # Find tnslsnr process, case-insensitive
    LSN_PID=$(ps -ef | grep -i tnslsnr | grep -i "$LNAME" | grep -v grep | awk '{print $2}' | head -n 1)
    log "DB $DB: alias '$LNAME' → listener PID = $LSN_PID"

    if [ -z "$LSN_PID" ]; then
      log "DB $DB: listener alias not found — skipping"
      continue
    fi

    if command -v ss >/dev/null 2>&1; then
      PORT=$(ss -ltnp 2>/dev/null | awk -v pid="$LSN_PID" '
        $0 ~ "pid=" pid "," {
          split($4,a,":");
          print a[length(a)]
        }' | head -n 1)
    else
      PORT=$(netstat -ltnp 2>/dev/null | awk -v pid="$LSN_PID" '
        $0 ~ pid"/" {
          split($4,a,":");
          print a[length(a)]
        }' | head -n 1)
    fi

    log "DB $DB: listener PID $LSN_PID listens on PORT $PORT"
  fi

  if [ -z "$PORT" ]; then
    log "DB $DB: failed to determine PORT — skipping"
    continue
  fi

  ###########################################################
  # 4) Add endpoints
  ###########################################################
  for svc in $SERVICES; do
    EP="${HOST}:${PORT}/${svc}"
    ENDPOINTS["$EP"]=1
    log "DB $DB: endpoint added → $EP"
  done

done < /etc/oratab

###########################################################
# 5) Build JSON: jq → python3 → python → pure bash
###########################################################
ENDPOINT_LIST=()
for ep in "${!ENDPOINTS[@]}"; do
  ENDPOINT_LIST+=( "$ep" )
done

HOST_KEY="$HOST"
FINAL_JSON=""
METHOD=""

# Method 1: jq
if command -v jq >/dev/null 2>&1; then
  PAYLOAD="[]"
  for ep in "${ENDPOINT_LIST[@]}"; do
    PAYLOAD=$(printf '%s' "$PAYLOAD" | jq --arg ep "$ep" '. += [$ep]')
  done
  FINAL_JSON=$(jq -n --arg host "$HOST_KEY" --argjson data "$PAYLOAD" '{($host): $data}')
  METHOD="jq"

# Method 2: python3
elif command -v python3 >/dev/null 2>&1; then
  FINAL_JSON=$(HOSTNAME="$HOST_KEY" ENDPOINTS="${ENDPOINT_LIST[*]}" python3 - <<'EOF'
import json, os
host = os.environ["HOSTNAME"]
arr  = os.environ["ENDPOINTS"].split()
print(json.dumps({host: arr}))
EOF
  )
  METHOD="python3"

# Method 3: python (2.x)
elif command -v python >/dev/null 2>&1; then
  FINAL_JSON=$(HOSTNAME="$HOST_KEY" ENDPOINTS="${ENDPOINT_LIST[*]}" python - <<'EOF'
import json, os
host = os.environ["HOSTNAME"]
arr  = os.environ["ENDPOINTS"].split()
print(json.dumps({host: arr}))
EOF
  )
  METHOD="python2"

# Method 4: pure bash fallback
else
  # Check for JSON-unsafe characters before attempting
  for ep in "${ENDPOINT_LIST[@]}"; do
    case "$ep" in
      *\"*|*\\*)
        echo "ERROR: unsafe characters in endpoint '$ep'; no jq/python available for escaping" >&2
        exit 1
        ;;
    esac
  done

  FINAL_JSON="{ \"$HOST_KEY\": ["
  first=1
  for ep in "${ENDPOINT_LIST[@]}"; do
    [ $first -eq 1 ] || FINAL_JSON+=", "
    FINAL_JSON+="\"$ep\""
    first=0
  done
  FINAL_JSON+="] }"
  METHOD="pure_bash"
fi

echo ""
echo "===== JSON Builder Used: $METHOD ====="
echo "$FINAL_JSON"
echo "===== END RUN ====="