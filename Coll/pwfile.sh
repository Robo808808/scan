check_dg_pwd_sync() {
  local ORACLE_SID="$1"

  if [[ -z "$ORACLE_SID" ]]; then
    echo "Usage: check_dg_pwd_sync ORACLE_SID" >&2
    return 2
  fi

  # Load Oracle env – adjust if you don't use oraenv
  local ORAENV_ASK=NO
  . oraenv <<< "$ORACLE_SID" >/dev/null 2>&1 || {
    echo "[FAIL] oraenv failed for SID=$ORACLE_SID" >&2
    return 2
  }

  local sql_out
  sql_out=$(sqlplus -s / as sysdba <<'SQL'
set pages 0 lines 200 feed off head off verify off echo off

select 'DB_VER='        || version       from v$instance;
select 'ROLE='          || database_role from v$database;
select 'DB_UNQ='        || db_unique_name from v$database;
select 'RDU='           || nvl(value,'<NULL>')
  from v$parameter
 where name = 'redo_transport_user';
select 'PWFILE_NAME='   || name          from v$passwordfile_info;
select 'PWFILE_TYPE='   || type          from v$passwordfile_info;
select 'IS_FAR_SYNC='   ||
       case when database_role like '%FAR SYNC%' then 'Y' else 'N' end
  from v$database;
SQL
)

  # Default values
  local DB_VER="" ROLE="" DB_UNQ="" RDU="" PWFILE_NAME="" PWFILE_TYPE="" IS_FAR_SYNC=""

  # Parse key=value output
  while IFS='=' read -r key val; do
    case "$key" in
      DB_VER)       DB_VER="$val" ;;
      ROLE)         ROLE="$val" ;;
      DB_UNQ)       DB_UNQ="$val" ;;
      RDU)          RDU="$val" ;;
      PWFILE_NAME)  PWFILE_NAME="$val" ;;
      PWFILE_TYPE)  PWFILE_TYPE="$val" ;;
      IS_FAR_SYNC)  IS_FAR_SYNC="$val" ;;
    esac
  done <<< "$sql_out"

  echo "=== DG SYS Password Propagation Pre-Check for $ORACLE_SID ($DB_UNQ) ==="
  echo "Database role       : $ROLE"
  echo "DB version          : $DB_VER"
  echo "Password file       : $PWFILE_NAME ($PWFILE_TYPE)"
  echo "redo_transport_user : $RDU"
  echo "Far Sync            : $IS_FAR_SYNC"
  echo

  # 1. Far Sync
  if [[ "$IS_FAR_SYNC" == "Y" ]]; then
    echo "[FAIL] Far Sync role → password file changes are NOT auto-propagated."
    return 1
  fi

  # 2. Version check (simple major.minor parse)
  local ver_major ver_minor
  ver_major=${DB_VER%%.*}
  ver_minor=${DB_VER#*.}; ver_minor=${ver_minor%%.*}

  if (( ver_major < 12 )) || (( ver_major == 12 && ver_minor < 2 )); then
    echo "[FAIL] DB version < 12.2 → no auto password-file propagation."
    return 1
  fi

  # 3. Password-file writable / location checks
  if [[ "$PWFILE_NAME" == +ASM* ]]; then
    echo "[OK] Password file stored in ASM – propagation-friendly."
  else
    if [[ -z "$PWFILE_NAME" ]]; then
      echo "[WARN] No password file reported in v\$passwordfile_info."
    elif [[ -w "$PWFILE_NAME" ]]; then
      echo "[OK] Password file is writable: $PWFILE_NAME"
    else
      echo "[FAIL] Password file not writable: $PWFILE_NAME"
      echo "       SYS password change may not propagate."
      return 1
    fi

    case "$PWFILE_NAME" in
      */dbs/orapw* )
        echo "[OK] Password file in standard location under \$ORACLE_HOME/dbs."
        ;;
      "" )
        : # already warned above
        ;;
      * )
        echo "[WARN] Password file in non-standard path: $PWFILE_NAME"
        echo "       Auto-propagation may not behave as expected."
        ;;
    esac
  fi

  # 4. redo_transport_user check
  if [[ "$RDU" == "<NULL>" || -z "$RDU" ]]; then
    echo "[INFO] redo_transport_user is NULL → SYS is transport user by default."
  else
    echo "[OK] redo_transport_user is $RDU → SYS password less critical for DG transport."
  fi

  echo
  echo "[RESULT] Check complete for $ORACLE_SID. Review FAIL/WARN messages above."
  return 0
}




WITH aud_enabled AS (
  SELECT 'Y' AS enabled
  FROM   audit_unified_enabled_policies
  WHERE  UPPER(user_name) = 'SYSTEM'
  UNION ALL
  SELECT 'Y'
  FROM   dba_stmt_audit_opts
  WHERE  username = 'SYSTEM'
), logins AS (
  SELECT COUNT(*) AS cnt
  FROM   unified_audit_trail
  WHERE  dbusername = 'SYSTEM'
  UNION ALL
  SELECT COUNT(*)
  FROM   sys.aud$
  WHERE  userid = 'SYSTEM'
)
SELECT
  COALESCE((SELECT enabled FROM aud_enabled FETCH FIRST 1 ROWS ONLY),'N') AS system_auditing_enabled,
  (SELECT SUM(cnt) FROM logins) AS system_login_events
FROM dual;
