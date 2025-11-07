import java.sql.*;
import java.time.Instant;

import oracle.ucp.jdbc.PoolDataSource;
import oracle.ucp.jdbc.PoolDataSourceFactory;

public class DemoTacUcp {
  public static void main(String[] args) throws Exception {

    // Dual-host descriptor (no SCAN). Replace <PRI_HOST> and <STBY_HOST>.
    String url =
      "jdbc:oracle:thin:@" +
      "(DESCRIPTION=" +
      " (CONNECT_TIMEOUT=20)(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=60)(RETRY_DELAY=2)" +
      " (ADDRESS_LIST=(LOAD_BALANCE=ON)" +
      "   (ADDRESS=(PROTOCOL=TCP)(HOST=<PRI_HOST>)(PORT=1521))" +
      "   (ADDRESS=(PROTOCOL=TCP)(HOST=<STBY_HOST>)(PORT=1521))" +
      " )" +
      " (CONNECT_DATA=(SERVICE_NAME=br_tac_svc))" +
      ")";

    PoolDataSource pds = PoolDataSourceFactory.getPoolDataSource();
    pds.setConnectionFactoryClassName("oracle.jdbc.pool.OracleDataSource");
    pds.setURL(url);
    pds.setUser("<USER>");
    pds.setPassword("<PASSWORD>");

    // Critical for TAC / AC:
    pds.setFastConnectionFailoverEnabled(true); // FAN+Reroute
    pds.setValidateConnectionOnBorrow(true);

    // Optional sizing:
    pds.setInitialPoolSize(1);
    pds.setMinPoolSize(1);
    pds.setMaxPoolSize(5);

    String sql =
      "MERGE INTO demo_tac_ac t " +
      "USING (SELECT ? id, ? note FROM dual) s " +
      "ON (t.id = s.id) " +
      "WHEN NOT MATCHED THEN INSERT (id, note) VALUES (s.id, s.note)";

    int id = 1001;

    System.out.println("Starting TAC test loop...");
    System.out.println("Perform a Broker switchover now — loop should continue without errors.");

    while (true) {
      String note = "JAVA-TAC " + Instant.now().toString();

      // Each iteration is a TAC replay boundary:
      try (Connection conn = pds.getConnection();
           PreparedStatement ps = conn.prepareStatement(sql)) {

        conn.setAutoCommit(false);
        ps.setInt(1, id);
        ps.setString(2, note);

        int rows = ps.executeUpdate();
        conn.commit();

        // Visible output:
        System.out.println("Upserted id=" + id + ", note='" + note + "', rows=" + rows);

      } catch (SQLException e) {
        // You will *not* see this on TAC-safe planned switchover.
        System.err.println("Database operation failed: " + e.getMessage());
      }

      Thread.sleep(1000);
    }
  }
}

