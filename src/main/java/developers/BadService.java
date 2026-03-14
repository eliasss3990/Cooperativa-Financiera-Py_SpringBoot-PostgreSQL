package developers;

import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;

public class BadService {

    // SonarCloud java:S2077 — SQL injection por concatenación de string (vulnerabilidad)
    public void queryUser(Connection conn, String username) throws SQLException {
        try (Statement stmt = conn.createStatement()) {
            stmt.execute("SELECT * FROM users WHERE name = '" + username + "'");
        }
    }

}
