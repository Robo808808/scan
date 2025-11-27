#!/bin/bash

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
LOG="/tmp/oracle_endpoint_post.log"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed" >&2
  exit 1
fi

declare -A ENDPOINTS

while IFS=':' read -r DB ORACLE_HOME Y; do
  [[ "$DB" =~ ^# || -z "$DB" ]] && continue
  PMON=$(pgrep -f "pmon_${DB}") || continue

  export ORACLE_HOME
  export ORACLE_SID="$DB"
  export PATH="$ORACLE_HOME/bin:$PATH"

  # Ask the DB which port users actually connect to
  PORT=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off echo off
select sys_context('userenv','server_port') from dual;
EOF
)
  PORT=$(echo "$PORT" | tr -d '[:space:]')
  [[ -z "$PORT" ]] && continue

  # Retrieve public root services (con_id 0 or 1)
  SERVICES=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off heading off verify off echo off
SELECT name
FROM v\$services
WHERE network_name IS NOT NULL
  AND con_id IN (0,1)
  AND name NOT LIKE '%XDB%'
  AND name NOT LIKE '%_DGMGRL%'
  AND name NOT LIKE '%_CFG'
  AND name NOT LIKE 'SYS\$%'
  AND name NOT LIKE 'PDB\$SEED%'
ORDER BY name;
EOF
)
  SERVICES=$(printf "%s\n" "$SERVICES" | sed '/^$/d')
  [[ -z "$SERVICES" ]] && continue

  # Build endpoints for this DB
  for svc in $SERVICES; do
    ENDPOINTS["${HOST}:${PORT}/${svc}"]=1
  done

done < /etc/oratab

# JSON build + POST
PAYLOAD="[]"
for ep in "${!ENDPOINTS[@]}"; do
  PAYLOAD=$(printf '%s\n' "$PAYLOAD" | jq -c --arg ep "$ep" '. += [$ep]')
done

FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

curl -s -X POST -H "Content-Type: application/json" -d "$FINAL_JSON" "$API_URL" >/dev/null 2>&1
echo "$FINAL_JSON"