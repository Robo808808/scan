check_dg_pwd_sync() {
  local ORACLE_SID=$1
  local ORAENV_ASK=NO
  . oraenv <<< "$ORACLE_SID" >/dev/null

  local sql_out
  sql_out=$(sqlplus -s / as sysdba <<EOF
set heading off feedback off trimspool on lines 200
SELECT
  (SELECT version FROM v\\$instance),
  (SELECT database_role FROM v\\$database),
  (SELECT db_unique_name FROM v\\$database),
  (SELECT value FROM v\\$parameter WHERE name='redo_transport_user'),
  (SELECT name FROM v\\$database),
  (SELECT status FROM v\\$instance),
  (SELECT type FROM v\\$passwordfile_info),
  (SELECT is_primary FROM v\\$dataguard_stats WHERE name='transport lag'),
  (SELECT name FROM v\\$passwordfile_info),
  (SELECT sys_context('userenv','instance_name') FROM dual)
FROM dual;
EXIT;
EOF
)

  # Extract fields
  DB_VER=$(echo "$sql_out" | awk '{print $1}')
  ROLE=$(echo "$sql_out" | awk '{print $2}')
  DB_UNQ=$(echo "$sql_out" | awk '{print $3}')
  RDU=$(echo "$sql_out" | awk '{print $4}')
  PWFILE_TYPE=$(echo "$sql_out" | awk '{print $7}')
  PWFILE_NAME=$(echo "$sql_out" | awk '{print $9}')

  echo "=== DG SYS Password Propagation Pre-Check for \$ORACLE_SID (\$DB_UNQ) ==="
  echo "Database role     : \$ROLE"
  echo "DB version        : \$DB_VER"
  echo "Password file     : \$PWFILE_NAME (\$PWFILE_TYPE)"
  echo "redo_transport_user: \$RDU"
  echo

  # 1. Far Sync
  if [[ "\$ROLE" == "PHYSICAL FAR SYNC" || "\$ROLE" == "FAR SYNC" ]]; then
    echo "[FAIL] Far Sync detected → SYS password auto-propagation will NOT occur."
    return 1
  fi

  # 2. DB version < 12.2 means no auto propagation
  ver_major=\${DB_VER%%.*}
  ver_minor=\${DB_VER#*.}
  ver_minor=\${ver_minor%%.*}

  if (( ver_major < 12 )) || (( ver_major == 12 && ver_minor < 2 )); then
    echo "[FAIL] DB version < 12.2 → no auto propagation support."
    return 1
  fi

  # 3. Check if password file is writable
  if [[ \$PWFILE_NAME == +ASM* ]]; then
    echo "[OK] Password file in ASM → writable for propagation"
  else
    if [[ -w "\$PWFILE_NAME" ]]; then
      echo "[OK] Password file writable"
    else
      echo "[FAIL] Password file not writable → SYS password change may break DG"
      return 1
    fi
  fi

  # 4. Password file outside standard FS path
  case "\$PWFILE_NAME" in
    */dbs/orapw*|+ASM/*)
      echo "[OK] Password file in standard location"
      ;;
    *)
      echo "[WARN] Password file in nonstandard path → auto propagation may fail"
      ;;
  esac

  # 5. redo_transport_user null = SYS used
  if [[ -z "\$RDU" ]]; then
    echo "[INFO] redo_transport_user is NULL → SYS used for redo transport"
  else
    echo "[OK] redo_transport_user set to non-SYS → SYS password change won’t break DG transport"
  fi

  echo "[RESULT] No blockers detected. SYS password change should not break Data Guard on this node."
  return 0
}
