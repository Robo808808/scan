#!/usr/bin/env bash
# Usage: sys_audit_simple.sh /path/to/adump > sys_syslogons.csv

set -eu

AUD_DIR="$1"
OUT="${2:-/tmp/sys_syslogons.csv}"

echo "timestamp,file,database_user,client_address,client_user,status,action" > "$OUT"

for f in "$AUD_DIR"/*; do
  [ -f "$f" ] || continue

  awk -v FILE="$f" '
    BEGIN { RS=""; FS="\n" }
    {
      ts = $1        # first line is timestamp in your format
      dbu = ""; addr = ""; cuser = ""; status = ""; act = ""

      for (i = 1; i <= NF; i++) {
        line = $i
        gsub(/^[ \t]+|[ \t]+$/, "", line)

        # DATABASE USER:[3] '\''SYS'\''
        if (toupper(line) ~ /^DATABASE USER/) {
          n = split(line, a, "'\''")
          if (n >= 2) dbu = toupper(a[2])
        }

        # CLIENT ADDRESS:[55] '\''ADDRESS=(...)'\''
        if (toupper(line) ~ /^CLIENT ADDRESS/) {
          n = split(line, a, "'\''")
          if (n >= 2) addr = a[2]
        }

        # CLIENT USER:[6] '\''oracle'\''
        if (toupper(line) ~ /^CLIENT USER/) {
          n = split(line, a, "'\''")
          if (n >= 2) cuser = a[2]
        }

        # STATUS:[1] '\''0'\''
        if (toupper(line) ~ /^STATUS/) {
          n = split(line, a, "'\''")
          if (n >= 2) status = a[2]
        }

        # ACTION :[27] '\''select name from v$database'\''
        if (toupper(line) ~ /^ACTION/) {
          n = split(line, a, "'\''")
          if (n >= 2) act = a[2]
        }
      }

      # We ONLY care about: DATABASE USER = SYS AND CLIENT ADDRESS not empty
      if (dbu != "SYS") next
      if (addr ~ /^[ \t]*$/) next

      # basic CSV escaping for commas/quotes
      gsub(/"/,"\"\"",ts)
      gsub(/"/,"\"\"",addr)
      gsub(/"/,"\"\"",cuser)
      gsub(/"/,"\"\"",status)
      gsub(/"/,"\"\"",act)

      printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n",
             ts, FILE, dbu, addr, cuser, status, act
    }
  ' "$f" >> "$OUT"
done

echo "Wrote results to $OUT" >&2
