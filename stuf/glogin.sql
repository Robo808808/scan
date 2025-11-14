Issue - glogin/login.sql has banner that is printed on sqlplus. When using script to collect variable then banner info is also pulled.

Load order 1) sqlplus runs global profile: glogin.sql from $ORACLE_HOME/sqlplus/admin/ 2) runs profile login.sql from: current working directory, or directory on ORACLE_PATH

Therefore put the banner in login.sql and keep glogin.sql quiet.
Reqires Batch scripts to not run from home as login.sql likely to be there.

-- glogin.sql (quiet, automation-friendly)
set termout on
set feedback on
set serveroutput on size 1000000
-- any other common settings you actually want everywhere


Another suggestion is to define variable that then gets called, e.g.

-- glogin.sql
-- Only show banner if environment variable SQLPLUS_BANNER is set to YES

column v_env new_value SQLPLUS_BANNER
set termout off
-- This pulls an env variable into a substitution variable via an external table trick or similar;
-- simplest is to rely on substitution: &SQLPLUS_BANNER will be empty if not defined.
set termout on

define SQLPLUS_BANNER='&SQLPLUS_BANNER'

-- Only print banner when explicitly requested
column dummy new_value _BATCH
select '&SQLPLUS_BANNER' dummy from dual;

-- If SQLPLUS_BANNER = YES, print banner
prompt
prompt ************************************************************
prompt *      CORPORATE BANNER – INTERACTIVE USE ONLY            *
prompt ************************************************************
prompt


export SQLPLUS_BANNER=YES
sqlplus user/pass@db

(change so SQLPL)