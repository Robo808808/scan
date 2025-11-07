using System;
using System.Threading.Tasks;
using Oracle.ManagedDataAccess.Client;

class Program {
  static async Task Main() {
    var cs = "User Id=<USER>;Password=<PASSWORD>;" +
             "Data Source=//<SCAN-or-host>:1521/br_tac_svc;" +
             "Application Continuity=true;" +     // enable AC/TAC logging & replay
             "HA Events=true;Load Balancing=true;Pooling=true";
    using var con = new OracleConnection(cs);
    await con.OpenAsync();

    using var cmd = con.CreateCommand();
    cmd.CommandText =
      "MERGE INTO demo_tac_ac t " +
      "USING (SELECT :id id, :note note FROM dual) s " +
      "ON (t.id = s.id) " +
      "WHEN NOT MATCHED THEN INSERT (id, note) VALUES (s.id, s.note)";
    cmd.Parameters.Add("id", 1002);

    Console.WriteLine("Running… update every 1s. Perform a switchover now.");
    while (true) {
      cmd.Parameters.RemoveAt("note");
      cmd.Parameters.Add("note", $"DOTNET-AC {DateTime.UtcNow:O}");
      await cmd.ExecuteNonQueryAsync();  // AC/TAC can safely replay
      using var tx = con.BeginTransaction(); tx.Commit(); // commit outcome path
      await Task.Delay(1000);
    }
  }
}