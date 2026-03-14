package developers;

public class BadService {

    // SonarCloud java:S2068 — credencial hardcodeada (vulnerabilidad)
    private static final String DB_PASSWORD = "supersecret123";

    public String getPassword() {
        return DB_PASSWORD;
    }

}
