

What acchk Is  

acchk is Oracle’s Application Continuity / Transparent Application Continuity analysis tool.  

It is not a load-test or functional test tool.  

Instead, it observes and analyzes application database workloads to determine whether the SQL and transaction patterns are deterministic — i.e., safe to replay.  

You run it on a database session, or against AWR/ASH traces, and it produces a report that tells you:  

What it Evaluates	Why it Matters  
Whether SQL operations are repeatable	TAC/AC only replay safe work  
Whether calls are ordered and consistent	Needed for replay state capture  
Use of sequences, sysdate, randomness	These may break determinism  
Use of PL/SQL, stateful calls, Temp tables	Replayability depends on state capture rules  
Whether commits occur at logical transaction points	Required for replay boundaries  

In short:  

acchk answers “Can we safely replay this application?”  

Does acchk Apply to Both TAC and AC?  
Feature	Supported by acchk?	Why  
Application Continuity (AC)	✅ Yes	AC needs to know if replay is safe  
Transparent Application Continuity (TAC)	✅ Yes	TAC uses the same replay engine; determinism still required  

So acchk is valid for BOTH AC and TAC.  

TAC is “transparent” in how it is enabled, but not in whether replay is always possible — the same determinism rules apply.  

If acchk says replay is unsafe, neither AC nor TAC will protect that transaction.  

What acchk Does Not Do
It Does	It Does Not
Analyze SQL patterns	Simulate outages
Identify unsafe replay sequences	Validate client-side JDBC settings
Highlight session state complexity	Confirm configuration of services/UCP/ons/TNS
Produce a replay-safety score	Confirm end-to-end failover behavior

-- run for current session  
exec dbms_app_cont_acchk.capture(NULL, NULL);  

exec dbms_app_cont_acchk.analyze_workload(  
  begin_time => systimestamp - interval '1' hour,  
  end_time   => systimestamp  
);  

USER_ACCHK_REPORT  
or  
DBA_ACCHK_REPORT  


Other Ways to Discover Whether an Application Is Deterministic
Method	Purpose	When to Use  
acchk	Static workload analysis	Pre-implementation review  
ACCHK TRACE mode	Observes real session execution during runtime	During early testing  
Replay WebLogic Diagnostic Logs / JDBC Replay Stats	Measures actual replay success	After TAC is enabled  
Database Views (V$AC_REMOTE_REPLAY_STATS, V$SESSION, V$APP_REPLAY)	Observe success/failure of live replays	Post-deployment monitoring  
Controlled failover testing	Real proof of TAC behavior	UAT/Pre-Production  