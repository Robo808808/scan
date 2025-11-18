#!/usr/bin/env python3
"""
discover_sys_audit.py

Run as oracle on the DB server. Uses OS-authenticated sqlplus (/ as sysdba)
to discover audit destinations and to pull unified/traditional audit rows for
SYS/SYSTEM, then scans audit dump files for SYS CONNECT events.

Usage:
  chmod +x discover_sys_audit.py
  ./discover_sys_audit.py --output /tmp/sys_audit_findings.csv

Notes:
- Requires sqlplus in PATH (or ORACLE_HOME/bin in PATH).
- Script uses bequeath connection by setting ORACLE_SID and running:
    sqlplus -S / as sysdba
- Be cautious with permissions; results may contain sensitive data.
"""

import os, sys, argparse, subprocess, re, csv, fnmatch, tempfile, shutil, datetime

# ------------------------
# Helpers
# ------------------------
def parse_oratab(path="/etc/oratab"):
    sids = []
    if not os.path.exists(path):
        return sids
    with open(path, 'r') as f:
        for line in f:
            line=line.strip()
            if not line or line.startswith('#'):
                continue
            parts=line.split(':')
            if len(parts) >= 2:
                sid = parts[0].strip()
                home = parts[1].strip()
                if sid and sid.upper() != 'HOSTNAME':
                    sids.append((sid, home))
    return sids

def run_sqlplus(env, sql):
    """Run sqlplus -S / as sysdba with env dict; return stdout as list of lines"""
    cmd = ['sqlplus', '-S', '/ as sysdba']
    # build a here-doc style input that prints a known marker and quits cleanly
    wrapper = "\n".join([
        "SET FEEDBACK OFF",
        "SET HEADING OFF",
        "SET PAGESIZE 0",
        "SET LINESIZE 1000",
        "SET TRIMSPOOL ON",
        "SET TRIMOUT ON",
        "SET COLSEP '|'",
        sql,
        "EXIT"
    ]) + "\n"
    try:
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
        out, err = p.communicate(wrapper, timeout=60)
    except Exception as e:
        return False, f"SQL*Plus invocation failed: {e}"
    if p.returncode != 0:
        # include stderr in failure reason
        return False, err.strip() or out.strip()
    # normalize output lines
    lines = [ln.rstrip() for ln in out.splitlines() if ln.strip()!='']
    return True, lines

def query_parameter(env, param_name):
    sql = f"SELECT value FROM v$parameter WHERE name = '{param_name}';"
    ok, res = run_sqlplus(env, sql)
    if not ok:
        return None, res
    if res:
        return res[0].strip(), None
    return None, None

def query_unified_audit(env, limit=200):
    # produce pipe-delimited lines: timestamp|dbusername|client_host|client_program|os_username|returncode
    sql = (
        "SELECT TO_CHAR(event_timestamp,'YYYY-MM-DD HH24:MI:SS') || '|' || "
        "NVL(dbusername,'') || '|' || NVL(client_host,'') || '|' || NVL(client_program_name,'') || '|' || NVL(os_username,'') || '|' || NVL(TO_CHAR(return_code),'') "
        "FROM unified_audit_trail "
        "WHERE dbusername IN ('SYS','SYSTEM') AND action_name='LOGON' "
        "ORDER BY event_timestamp DESC FETCH FIRST %d ROWS ONLY;" % limit
    )
    ok, res = run_sqlplus(env, sql)
    if not ok:
        return None, res
    return res, None

def query_traditional_audit(env, limit=200):
    # query DBA_AUDIT_SESSION
    sql = (
        "SELECT TO_CHAR(timestamp,'YYYY-MM-DD HH24:MI:SS') || '|' || "
        "NVL(username,'') || '|' || NVL(os_username,'') || '|' || NVL(userhost,'') || '|' || NVL(terminal,'') || '|' || NVL(TO_CHAR(returncode),'') "
        "FROM dba_audit_session "
        "WHERE username IN ('SYS','SYSTEM') "
        "ORDER BY timestamp DESC FETCH FIRST %d ROWS ONLY;" % limit
    )
    ok, res = run_sqlplus(env, sql)
    if not ok:
        return None, res
    return res, None

# ------------------------
# Audit file scanning heuristics (conservative)
# ------------------------
def find_audit_files(directory, max_files=1000):
    out = []
    if not os.path.isdir(directory):
        return out
    for root, dirs, files in os.walk(directory):
        for f in files:
            if f.lower().endswith('.aud') or fnmatch.fnmatch(f, 'ora_*.aud') or f.lower().endswith('.log'):
                out.append(os.path.join(root, f))
    out.sort(key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0, reverse=True)
    if max_files and max_files>0:
        return out[:max_files]
    return out

def scan_aud_file_for_sys(path):
    findings = []
    try:
        with open(path, 'r', errors='ignore') as fh:
            text = fh.read()
    except Exception:
        return findings
    # split into blocks separated by blank lines or lines of ----
    blocks = re.split(r"\n\s*\n|(?:\n-+\n)", text)
    for b in blocks:
        if 'DATABASE USER' in b.upper() and 'SYS' in b.upper():
            # quick heuristic checks
            db_user = ''
            if m := re.search(r"DATABASE USER\s*:\s*['\"]?([A-Z0-9_]+)['\"]?", b, re.IGNORECASE):
                db_user = m.group(1).upper()
            action = ''
            if m := re.search(r"ACTION\s*:\s*'?\s*([A-Z_ ]+)\s*'?", b, re.IGNORECASE):
                action = m.group(1).strip().upper()
            if db_user == 'SYS' and action.startswith('CONNECT'):
                client_addr = ''
                if m := re.search(r"CLIENT ADDRESS\s*:\s*(.+)", b, re.IGNORECASE):
                    client_addr = m.group(1).strip()
                program = ''
                if m := re.search(r"PROGRAM\s*:\s*['\"]?([^\n']+)['\"]?", b, re.IGNORECASE):
                    program = m.group(1).strip()
                auth = ''
                if m := re.search(r"AUTHENTICATION\s*:\s*['\"]?([A-Z0-9_ -]+)['\"]?", b, re.IGNORECASE):
                    auth = m.group(1).strip().upper()
                # heuristics for remote vs local
                location = 'unknown'
                method = 'unknown'
                if re.search(r"PROTOCOL\s*=\s*tcp", b, re.IGNORECASE) or re.search(r"\bHOST\s*=", b, re.IGNORECASE) or re.search(r"\b\d{1,3}(\.\d{1,3}){3}\b", b):
                    location = 'remote'
                    if 'PASS' in auth:
                        method = 'password'
                    else:
                        method = 'likely-password'
                if re.search(r"PROTOCOL\s*=\s*BEQ", b, re.IGNORECASE) or re.search(r"\bLOCAL\b", b, re.IGNORECASE) or 'BEQ' in b.upper():
                    location = 'local'
                    if 'PASS' in auth:
                        method = 'password'
                    else:
                        method = 'local-auth'
                if 'sqlplus' in program.lower() and method == 'unknown':
                    method = 'possible-password-in-cmdline'
                findings.append({
                    'file': path,
                    'db_user': db_user,
                    'action': action,
                    'client_address': client_addr,
                    'program': program,
                    'auth': auth,
                    'detected_method': method,
                    'detected_location': location
                })
    return findings

# ------------------------
# Main driver
# ------------------------
def main():
    p = argparse.ArgumentParser(description="Discover DB SIDs, query audit config, and scan audit files for SYS connects.")
    p.add_argument('--oratab', default='/etc/oratab')
    p.add_argument('--output', default='/tmp/sys_audit_findings.csv')
    p.add_argument('--max-audit-files', type=int, default=500)
    p.add_argument('--limit-audit-rows', type=int, default=200)
    args = p.parse_args()

    sids = parse_oratab(args.oratab)
    if not sids:
        print("No SIDs found in /etc/oratab; exiting.")
        return 1

    all_findings = []
    for sid, home in sids:
        print(f"\n=== SID: {sid} (ORACLE_HOME={home or '<unknown>'}) ===")
        # prepare environment for bequeath connection
        env = os.environ.copy()
        env['ORACLE_SID'] = sid
        if home:
            env['ORACLE_HOME'] = home
            env['PATH'] = os.path.join(home, 'bin') + ':' + env.get('PATH','')
        # 1) discover audit_file_dest and audit_sys_operations
        audit_file_dest, err = query_parameter(env, 'audit_file_dest')
        if err:
            print(f"  [!] Could not query audit_file_dest: {err}")
        else:
            print(f"  audit_file_dest = {audit_file_dest}")

        audit_sys_ops, err = query_parameter(env, 'audit_sys_operations')
        if err:
            print(f"  [!] Could not query audit_sys_operations: {err}")
        else:
            print(f"  audit_sys_operations = {audit_sys_ops}")

        # 2) detect unified auditing support
        ok, val = run_sqlplus(env, "SELECT value FROM v$option WHERE parameter='Unified Auditing';")
        unified_enabled = False
        if ok and val:
            if len(val)>0 and val[0].strip().upper().startswith('TRUE'):
                unified_enabled = True
        print(f"  Unified Auditing: {'YES' if unified_enabled else 'NO'}")

        # 3) fetch audit rows from DB audit tables
        if unified_enabled:
            rows, err = query_unified_audit(env, limit=args.limit_audit_rows)
            if rows is None:
                print(f"  [!] Failed to query unified_audit_trail: {err}")
            else:
                print(f"  unified_audit_trail rows found: {len(rows)} (showing up to {args.limit_audit_rows})")
                for r in rows[:10]:
                    # timestamp|dbusername|client_host|client_program|os_username|returncode
                    parts = r.split('|')
                    all_findings.append({
                        'sid': sid,
                        'source': 'unified_audit_trail',
                        'row': r,
                        'timestamp': parts[0] if len(parts)>0 else '',
                        'dbusername': parts[1] if len(parts)>1 else '',
                        'client_host': parts[2] if len(parts)>2 else '',
                        'client_program': parts[3] if len(parts)>3 else '',
                        'os_username': parts[4] if len(parts)>4 else '',
                        'return_code': parts[5] if len(parts)>5 else ''
                    })
        else:
            rows, err = query_traditional_audit(env, limit=args.limit_audit_rows)
            if rows is None:
                print(f"  [!] Failed to query dba_audit_session: {err}")
            else:
                print(f"  dba_audit_session rows found: {len(rows)} (showing up to {args.limit_audit_rows})")
                for r in rows[:10]:
                    parts = r.split('|')
                    all_findings.append({
                        'sid': sid,
                        'source': 'dba_audit_session',
                        'row': r,
                        'timestamp': parts[0] if len(parts)>0 else '',
                        'dbusername': parts[1] if len(parts)>1 else '',
                        'os_username': parts[2] if len(parts)>2 else '',
                        'userhost': parts[3] if len(parts)>3 else '',
                        'terminal': parts[4] if len(parts)>4 else '',
                        'return_code': parts[5] if len(parts)>5 else ''
                    })

        # 4) If audit_file_dest exists and path is local, scan files
        if audit_file_dest:
            ad = audit_file_dest.strip().strip("'\"")
            if os.path.isdir(ad):
                print(f"  Scanning audit directory: {ad}")
                files = find_audit_files(ad)
                print(f"    found {len(files)} candidate audit files (scanning up to {args.max_audit_files})")
                if args.max_audit_files and args.max_audit_files>0:
                    files = files[:args.max_audit_files]
                for fpath in files:
                    ffind = scan_aud_file_for_sys(fpath)
                    for ff in ffind:
                        rec = {'sid': sid, 'source': 'audit_file', 'file': ff['file'],
                               'db_user': ff['db_user'], 'action': ff['action'],
                               'client_address': ff['client_address'], 'program': ff['program'],
                               'auth': ff['auth'], 'detected_method': ff['detected_method'],
                               'detected_location': ff['detected_location']}
                        all_findings.append(rec)
            else:
                print(f"  audit_file_dest '{ad}' not found as directory on filesystem (may be NFS or different ORACLE_BASE).")
        else:
            print("  No audit_file_dest returned; skipping audit file scan for this SID.")

    # ------------------------
    # Write CSV
    # ------------------------
    if all_findings:
        keys = sorted({k for d in all_findings for k in d.keys()})
        # ensure some consistent ordering
        preferred = ['sid','source','file','row','timestamp','dbusername','db_user','action','client_address','client_host','program','client_program','os_username','userhost','terminal','auth','detected_method','detected_location','return_code']
        keys = [k for k in preferred if k in keys] + [k for k in keys if k not in preferred]
        outdir = os.path.dirname(args.output) or '/tmp'
        os.makedirs(outdir, exist_ok=True)
        with open(args.output, 'w', newline='') as csvf:
            w = csv.DictWriter(csvf, fieldnames=keys)
            w.writeheader()
            for r in all_findings:
                w.writerow({k: r.get(k,'') for k in keys})
        print(f"\nWrote {len(all_findings)} findings to {args.output}")
    else:
        print("\nNo findings to write.")

    # short summary:
    remote_pass = [r for r in all_findings if r.get('detected_method') in ('password','likely-password','possible-password-in-cmdline') and r.get('detected_location')=='remote']
    local_pass = [r for r in all_findings if r.get('detected_method') in ('password','possible-password-in-cmdline','local-auth') and r.get('detected_location')=='local']
    print(f"\nSummary: total records={len(all_findings)}; probable-remote-password={len(remote_pass)}; probable-local-password={len(local_pass)}")
    if all_findings:
        print("\nSample:")
        for s in all_findings[:10]:
            print(" ", {k:v for k,v in s.items() if k in ('sid','source','file','db_user','dbusername','timestamp','client_address','program','detected_method','detected_location')})
    return 0

if __name__ == '__main__':
    sys.exit(main())
