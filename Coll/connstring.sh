#!/bin/bash
# Discover the Oracle CDB *root* service connection string(s) and send to API

API_URL="https://central.server.example.com/collect/oracle/endpoints"
HOST=$(hostname -s)
TMPFILE="/tmp/oracle_root_services.txt"
LOG="/tmp/oracle_endpoint_post.log"

# Reset file
> "$TMPFILE"

# Run SQL for CDB root services only
# Rules:
# - If CDB: only include services mapped to CON_ID=0 (CDB$ROOT)
# - If non-CDB: return all services (traditional DB)
sqlplus -s / as sysdba <<EOF > "$TMPFILE"
set pages 0 feedback off heading off verify off echo off
WITH svc AS (
  SELECT name, con_id
  FROM v\$services
  WHERE network_name IS NOT NULL
),
root_svc AS (
  SELECT name FROM svc WHERE con_id = 0
),
fallback AS (
  SELECT name FROM svc
)
SELECT name FROM root_svc
UNION
SELECT name FROM fallback WHERE NOT EXISTS (SELECT 1 FROM root_svc);
EOF

# Discover listener host:port(s)
LISTENERS=$(lsnrctl status 2>/dev/null | awk '/ADDRESS=/ {
  if (match($0, /HOST=([^)]*)/ , h) && match($0, /PORT=([0-9]*)/, p))
    print h[1] ":" p[1];
}' | sort -u)

# Build JSON payload
PAYLOAD="[]"
while read -r svc; do
  [[ -z "$svc" ]] && continue
  for L in $LISTENERS; do
    ep="${L}/${svc}"
    PAYLOAD=$(echo "$PAYLOAD" | jq -c --arg ep "$ep" '. += [$ep]')
  done
done < "$TMPFILE"

FINAL_JSON=$(jq -n --arg host "$HOST" --argjson data "$PAYLOAD" '{($host): $data}')

# POST to FastAPI
RESP=$(curl -s -o /tmp/endpoint_resp.json -w "%{http_code}" \
  -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "$FINAL_JSON")

# Log success or failure
if [[ "$RESP" == "200" || "$RESP" == "201" ]]; then
  echo "$(date) OK $HOST endpoints posted ($RESP)" >> "$LOG"
else
  echo "$(date) ERROR posting endpoints ($RESP) Payload=${FINAL_JSON}" >> "$LOG"
fi

echo "$FINAL_JSON"