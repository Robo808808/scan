#!/bin/bash
#
# Discover Oracle "public" CDB root services per database and POST
# them to a FastAPI collector in JSON form:
# { "hostname": [ "host:port/service" , ... ] }
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
# STEP 1 — discover all listener ports via ss/netstat
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
                  }' | sort -u)
else
  while read -r port; do
    [[ -n "$port" ]] && GLOBAL_PORTS+=("$port")
  done < <(netstat -ltnp 2>/dev/null \
           | awk '/tnslsnr/ && /LISTEN/ {
                    split($4,a,":");
                    p=a[length(a)];
                    if (p ~ /^[0-9]+$/) print p
                  }' | sort -u)
fi

if [[ ${#GLOBAL_PORTS[@]} -eq 0 ]]; then
  echo "$(date) WARNING: no listener ports discovered via ss/netstat on $HOST" >> "$LOG"
fi

#############################################
# STEP 2 — loop /etc/oratab, per-DB discover:
#   - is DB up?
#   - LOCAL_LISTENER port (if any)
#   - filtered root services
#############################################

declare -A ENDPOINTS   # unique map: "host:port/service" → 1

while IFS=':' read -r DB ORACLE_HOME Y; do
  # Skip comments/blank lines
  [[ "$DB" =~ ^# || -z "$DB" ]] && continue

  # Skip ASM if present (optional)
  # [[ "$DB" == *"+"* ]] && continue

  # Check DB is running via PMON
  if ! ps -ef | grep -q "[p]mon_${DB}"; then
    echo "$(date) DB $DB not running — skipping" >> "$LOG"
    continue
  fi

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  #########################
  # 2a — get LOCAL_LISTENER
  #########################
  LL_RAW=$(sqlplus -s / as sysdba <<'EOF'
set pages 0 feedback off heading off verify off echo off
select value from v$parameter where name = 'local_listener';
EOF
)
  LOCAL_LISTENER=$(printf "%s\n" "$LL_RAW" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | head -n1)

  DB_PORTS=()

  # If LOCAL_LISTENER contains an explicit PORT, extract it
  if [[ "$LOCAL_LISTENER" =~ PORT[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
    DB_PORTS+=("${BASH_REMATCH[1]}")
  fi

  # If we still have no port for this DB, fall back to all discovered ports
  if [[ ${#DB_PORTS[@]} -eq 0 ]]; then
    DB_PORTS=("${GLOBAL_PORTS[@]}")
  fi

  #########################
  # 2b — get filtered root services for this DB
  #########################
  SQL_SVC=$(sqlplus -s / as sysdba <<'EOF'
set pages 0 feedback off heading off verify off echo off
SELECT name
FROM v$services
WHERE network_name IS NOT NULL
  AND con_id = 0
  AND name NOT LIKE '%XDB%'
  AND name NOT LIKE '%_DGMGRL%'
  AND name NOT LIKE '%_CFG'
  AND name NOT LIKE 'SYS$%'
  AND name NOT LIKE 'PDB$SEED%'
ORDER BY name;
EOF
)
  SERVICES=$(printf "%s\n" "$SQL_SVC" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')

  if [[ -z "$SERVICES" ]]; then
    echo "$(date) No filtered services returned for $DB on $HOST" >> "$LOG"
    continue
  fi

  #########################
  # 2c — build endpoints
  #########################
  for port in "${DB_PORTS[@]}"; do
    [[ -z "$port" ]] && continue
    for svc in $SERVICES; do
      ep="${HOST}:${port}/${svc}"
      ENDPOINTS["$ep"]=1
    done
  done

done < /etc/oratab

#############################################
# STEP 3 — build JSON + POST
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
  echo "$(date) OK posted for $HOST ($RESP)" >> "$LOG"
else
  echo "$(date) ERROR posting for $HOST code=$RESP payload=$FINAL_JSON" >> "$LOG"
fi

echo "$FINAL_JSON"
