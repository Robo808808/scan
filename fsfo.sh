sudo bash -lc 'set -euo pipefail; PKG=$(command -v dnf || command -v yum); ELREL=$(grep -oE "release ([0-9]+)" /etc/redhat-release | awk "{print \$2}"); case "$ELREL" in 8) RELPKG=oracle-instantclient-release-el8 ;; 9) RELPKG=oracle-instantclient-release-el9 ;; *) echo "Unsupported EL release: $ELREL" >&2; exit 1 ;; esac; $PKG -y install $RELPKG || true; $PKG -y install oracle-instantclient-basic.x86_64 oracle-instantclient-tools.x86_64 oracle-instantclient-sqlplus.x86_64 unzip; IC_HOME=$(rpm -ql oracle-instantclient-basic | awk -F/ "/\\/usr\\/lib\\/oracle\\//{print \"/\"$3\"/\"$4\"/\"$5\"/\"$6\"/\"$7\"/\"$8\"\"; exit}"); mkdir -p /u01/observerfsfo /u01/app/oracle/network/admin; cat >/etc/profile.d/instantclient.sh <<EOF
export ORACLE_HOME=$IC_HOME
export PATH=\$ORACLE_HOME/bin:\$ORACLE_HOME:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME
export TNS_ADMIN=/u01/app/oracle/network/admin
EOF
chmod 0755 /etc/profile.d/instantclient.sh; echo "Installed. Open a new shell, then run: dgmgrl -v"'

bash -lc 'set -euo pipefail; : "${BASIC_ZIP:?Set BASIC_ZIP to the Basic zip URL}" "${SQLPLUS_ZIP:?Set SQLPLUS_ZIP to the SQL*Plus zip URL}" "${TOOLS_ZIP:?Set TOOLS_ZIP to the Tools zip URL}"; IC_TAG="${IC_TAG:-19_24}"; IC_HOME="${IC_HOME:-/u01/app/oracle/instantclient_${IC_TAG}}"; sudo mkdir -p "$IC_HOME" /u01/observerfsfo /u01/app/oracle/network/admin; sudo chown -R "$USER":"$USER" /u01/app; for u in "$BASIC_ZIP" "$SQLPLUS_ZIP" "$TOOLS_ZIP"; do f="/tmp/$(basename "$u")"; command -v curl >/dev/null || { sudo apt-get update -y 2>/dev/null || true; sudo apt-get install -y curl 2>/dev/null || sudo dnf -y install curl || sudo yum -y install curl; }; command -v unzip >/dev/null || { sudo apt-get update -y 2>/dev/null || true; sudo apt-get install -y unzip 2>/dev/null || sudo dnf -y install unzip || sudo yum -y install unzip; }; echo "Downloading $u"; curl -fsSL "$u" -o "$f"; echo "Extracting $f to $IC_HOME"; unzip -o -q "$f" -d "$IC_HOME"; done; # flatten path if needed
if [ -d "$IC_HOME/instantclient"* ]; then sub=$(find "$IC_HOME" -maxdepth 1 -type d -name "instantclient*" | head -n1); [ -n "$sub" ] && shopt -s dotglob && mv "$sub"/* "$IC_HOME"/ && rmdir "$sub"; fi
ENVFILE="/etc/profile.d/instantclient.sh"; sudo bash -lc "cat >$ENVFILE <<EOF
export ORACLE_HOME=$IC_HOME
export PATH=\\\$ORACLE_HOME:\\\$ORACLE_HOME/bin:\\\$PATH
export LD_LIBRARY_PATH=\\\$ORACLE_HOME
export TNS_ADMIN=/u01/app/oracle/network/admin
EOF
chmod 0755 $ENVFILE"; echo; echo "Done. Open a NEW shell so env vars apply, then run: dgmgrl -v"'


export BASIC_ZIP='https://download.oracle.com/otn_software/instantclient/198000/instantclient-basic-linux.x64-19.8.0.0.0dbru.zip'
export SQLPLUS_ZIP='https://download.oracle.com/otn_software/instantclient/198000/instantclient-sqlplus-linux.x64-19.8.0.0.0dbru.zip'
export TOOLS_ZIP='https://download.oracle.com/otn_software/instantclient/198000/instantclient-tools-linux.x64-19.8.0.0.0dbru.zip'
# optional:
export IC_TAG=19_8
export IC_HOME=/u01/app/oracle/instantclient_${IC_TAG}
# then run the one-liner above


dgmgrl -v
which dgmgrl
echo $ORACLE_HOME


dgmgrl sys@DBPRIM "start observer file='/u01/observerfsfo/observer.dat'"



mkdir /u01/observerfsfo/observer.log
mkdir /u01/observerfsfo/observer.err

sudo bash -lc 'set -euo pipefail
OBSERVICE=/etc/systemd/system/dgobserver.service
ORACLE_USER=oracle
TNS_CONNECT="sys@DBPRIM"
OBS_FILE="/u01/observerfsfo/observer.dat"
ORACLE_HOME=${ORACLE_HOME:-/usr/lib/oracle/19*/client64}
cat >"$OBSERVICE" <<EOF
[Unit]
Description=Oracle Data Guard FSFO Observer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ORACLE_USER}
Environment="ORACLE_HOME=${ORACLE_HOME}"
Environment="PATH=${ORACLE_HOME}/bin:/usr/bin:/bin"
ExecStart=${ORACLE_HOME}/bin/dgmgrl ${TNS_CONNECT} "start observer file='${OBS_FILE}'"
Restart=always
RestartSec=10
StandardOutput=append:/u01/observerfsfo/observer.log
StandardError=append:/u01/observerfsfo/observer.err

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dgobserver
systemctl start dgobserver
systemctl status dgobserver --no-pager'



sudo systemctl status dgobserver

