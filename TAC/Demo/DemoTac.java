import java.sql.*;
import java.time.Instant;
import java.util.Properties;
import oracle.ucp.jdbc.PoolDataSource;
import oracle.ucp.jdbc.PoolDataSourceFactory;

public class DemoTacUcp {
  public static void main(String[] args) throws Exception {
    String url =
      "jdbc:oracle:thin:@" +
      "(DESCRIPTION=(CONNECT_TIMEOUT=20)(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=60)(RETRY_DELAY=2)" +
      " (ADDRESS_LIST=(LOAD_BALANCE=ON)" +
      "   (ADDRESS=(PROTOCOL=TCP)(HOST=<PRI_HOST>)(PORT=1521))" +
      "   (ADDRESS=(PROTOCOL=TCP)(HOST=<STBY_HOST>)(PORT=1521))" +
      " )(CONNECT_DATA=(SERVICE_NAME=br_tac_svc)))";

    PoolDataSource pds = PoolDataSourceFactory.getPoolDataSource();
    pds.setConnectionFactoryClassName("oracle.jdbc.pool.OracleDataSource");
    pds.setURL(url);
    pds.setUser("<USER>");
    pds.setPassword("<PASSWORD>");
    pds.setFastConnectionFailoverEnabled(true);   // FAN/FCF on
    pds.setValidateConnectionOnBorrow(true);
    // Optional sizings
    pds.setInitialPoolSize(1);
    pds.setMinPoolSize(1);
    pds.setMaxPoolSize(5);

    String sql =
      "MERGE INTO demo_tac_ac t " +
      "USING (SELECT ? id, ? note FROM dual) s " +
      "ON (t.id = s.id) " +
      "WHEN NOT MATCHED THEN INSERT (id, note) VALUES (s.id, s.note)";

    int id = 1001;
    System.out.println("Running… update every 1s. Perform a switchover now.");

    while (true) {
      String note = "JAVA-TAC " + Instant.now().toString();
      try (Connection conn = pds.getConnection();
           PreparedStatement ps = conn.prepareStatement(sql)) {
        conn.setAutoCommit(false);
        ps.setInt(1, id);
        ps.setString(2, note);
        ps.executeUpdate();
        conn.commit();
        System.out.println("Upserted id=" + id + " note=" + note);
      }
      Thread.sleep(1000);
    }
  }
}
