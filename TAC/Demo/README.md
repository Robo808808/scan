## What your audience will see

Start one (or all) clients. They will print one message per second.  
Perform the switchover with Data Guard Broker.  
The clients keep printing. No ORA-03113/03135, no restarts.  

If you temporarily point the apps to a non-TAC/AC service, repeat the switchover: you’ll get visible errors — a powerful contrast.  


## Java

### Requires JDK 11+ and ojdbc8.jar on classpath (19c+)
javac -cp ojdbc8.jar DemoTac.java  
java  -cp .:ojdbc8.jar DemoTac  

JDBC needs the service (/br_tac_svc) and the property oracle.jdbc.enableACSupport=true.  


## ODP.NET
There is skeleton and program.cs files.  
To compile:  
dotnet run

## Python

python -m pip install oracledb

### Download & unzip Oracle Instant Client (19c+), then:
### Linux/macOS example:
python -c "import oracledb; oracledb.init_oracle_client(lib_dir='/opt/oracle/instantclient_19_20')"

python demo_tac_py.py
