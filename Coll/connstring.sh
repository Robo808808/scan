#!/bin/bash
#
# Discover Oracle "public" CDB root services per database and POST
# them to a FastAPI collector in JSON form:
#   { "hostname": [ "host:port/service", ... ] }
#
# Rules:
# - Only uses DB-side info (v$services, local_listener) + OS ports (ss/netstat)
# - No lsnrctl at all (avoids hangs due to env/profile issues)
# - For CDBs, root = con_id IN (0,1)
# - No XDB, SYS$, _CFG, _DGMGRL, PDB$SEED services
# - Returns ALL filtered root services per DB
# - Only maps a DB to a port if:
#       * local_listener has an explicit (PORT=nnnn), OR
#       * there is exactly one listener port on the host
#

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
LOG="/tmp/oracle_endpoint_post.log"

# Need jq
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed" >&2
  exit 1
fi

#############################################
# Step 1: discover all tnslsnr ports via ss/netstat
#############################################

GLOBAL_PORTS=()

if command -v ss >/dev/null 2>&1; then
  while read -r port; do
    [[ -n "$port" ]] && GLOBAL_PORTS+=("$port")
  done < <(ss -ltnp 2>/dev/null \
    | awk '/tnslsnr/ && /LISTEN/ {
             split($4,a,":");
             p=a[length(a)];
             if (p ~ /^[0-9]+$/) print p
           }' \
    | sort -u)
else
  while read -r port; do
    [[ -n "$port" ]] && GLOBAL_PORTS+=("$port")
  done < <(netstat -ltnp 2>/dev/null \
    | awk '/tnslsnr/ && /LISTEN/ {
             split($4,a,":");
             p=a[length(a)];
             if (p ~ /^[0-9]+$/) print p
           }' \
    | sort -u)
fi

if [[ ${#GLOBAL_PORTS[@]} -eq 0 ]]; then
  echo "$(date) WARNING: no listener ports discovered on $HOST" >> "$LOG"
fi

#############################################
# Step 2: per-DB: check PMON, derive ports, get services
#############################################

declare -A ENDPOINTS  # "host:port/service" -> 1

while IFS=':' read -r DB ORACLE_HOME Y; do
  # skip comments/blank
  [[ "$DB" =~ ^# || -z "$DB" ]] && continue

  # optional: skip ASM
  # [[ "$DB" == *"+"* ]] && continue

  # is DB up?
  if ! ps -ef | grep -q "[p]mon_${DB}"; then
    echo "$(date) DB $DB not running, skipping" >> "$LOG"
    continue
  fi

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  ###########################################
  # 2a: derive DB-specific ports from LOCAL_LISTENER
  ###########################################
  LL_RAW=$(sqlplus -s / as sysdba <<'EOF'
set pages 0 feedback off heading off verify off echo off
select value from v$parameter where name = 'local_listener';
EOF
)
  LOCAL_LISTENER=$(printf "%s\n" "$LL_RAW" \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
      | sed '/^$/d' \
      | head -n1)

  DB_PORTS=()

  # Try to extract explicit "(PORT=nnnn)" from LOCAL_LISTENER
  if [[ "$LOCAL_LISTENER" =~ PORT[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
    DB_PORTS+=("${BASH_REMATCH[1]}")
  fi

  # If no explicit port in local_listener:
  #   - If there's exactly one global listener port, use that (safe assumption)
  #   - If multiple listener ports exist, do NOT guess: skip this DB
  if [[ ${#DB_PORTS[@]} -eq 0 ]]; then
    if [[ ${#GLOBAL_PORTS[@]} -eq 1 ]]; then
      DB_PORTS=("${GLOBAL_PORTS[0]}")
      echo "$(date) DB $DB has no PORT in LOCAL_LISTENER, using sole listener port ${GLOBAL_PORTS[0]}" >> "$LOG"
    else
      echo "$(date) DB $DB has ambiguous/no LOCAL_LISTENER and multiple listener ports on host; skipping to avoid wrong mapping" >> "$LOG"
      continue
    fi
  fi

  ###########################################
  # 2b: get filtered root services for this DB (con_id 0/1)
  ###########################################
  SQL_SVC=$(sqlplus -s / as sysdba <<'EOF'
set pages 0 feedback off heading off verify off echo off
SELECT name
FROM v$services
WHERE network_name IS NOT NULL
  AND con_id IN (0,1)
  AND name NOT LIKE '%XDB%'
  AND name NOT LIKE '%_DGMGRL%'
  AND name NOT LIKE '%_CFG'
  AND name NOT LIKE 'SYS$%'
  AND name NOT LIKE 'PDB$SEED%'
ORDER BY name;
EOF
)
  SERVICES=$(printf "%s\n" "$SQL_SVC" \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
      | sed '/^$/d')

  if [[ -z "$SERVICES" ]]; then
    echo "$(date) DB $DB: no filtered root services found (con_id in (0,1))" >> "$LOG"
    continue
  fi

  ###########################################
  # 2c: build endpoints for this DB
  ###########################################
  for port in "${DB_PORTS[@]}"; do
    [[ -z "$port" ]] && continue
    for svc in $SERVICES; do
      ep="${HOST}:${port}/${svc}"
      ENDPOINTS["$ep"]=1
    done
  done

done < /etc/oratab

#############################################
# Step 3: build JSON and POST
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

if [[ "$RESP" == "200" || "$RESP" == "201" ]]; then
  echo "$(date) OK posted endpoints for $HOST ($RESP)" >> "$LOG"
else
  echo "$(date) ERROR posting endpoints for $HOST code=$RESP payload=$FINAL_JSON" >> "$LOG"
fi

echo "$FINAL_JSON"