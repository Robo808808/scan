import java.math.BigDecimal;
import java.sql.*;
import java.time.Instant;
import java.util.Properties;

public class DemoTac {
  public static void main(String[] args) throws Exception {
    String url = "jdbc:oracle:thin:@//<SCAN-or-host>:1521/br_tac_svc";
    Properties prop = new Properties();
    prop.setProperty("user", "<USER>");
    prop.setProperty("password", "<PASSWORD>");
    prop.setProperty("oracle.jdbc.enableACSupport", "true"); // TAC/AC on

    try (Connection conn = DriverManager.getConnection(url, prop)) {
      conn.setAutoCommit(false);
      PreparedStatement ps = conn.prepareStatement(
        "MERGE INTO demo_tac_ac t " +
        "USING (SELECT ? id, ? note FROM dual) s " +
        "ON (t.id = s.id) " +
        "WHEN NOT MATCHED THEN INSERT (id, note) VALUES (s.id, s.note)"
      );

      int id = 1001; // fixed, deterministic
      System.out.println("Running… update every 1s. Perform a switchover now.");
      while (true) {
        String note = "JAVA-TAC " + Instant.now().toString();
        ps.setInt(1, id);
        ps.setString(2, note);
        ps.executeUpdate();         // replay-safe request
        conn.commit();              // commit outcome tracked by service
        System.out.println("Upserted id=" + id + " note=" + note);
        Thread.sleep(1000);
      }
    }
  }
}