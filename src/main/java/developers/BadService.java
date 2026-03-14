package developers;

public class BadService {

    // SonarCloud java:S2068 — credencial hardcodeada (security hotspot)
    private static final String DB_PASSWORD = "supersecret123";

    // SonarCloud java:S1764 — subexpresiones idénticas en operador lógico (bug)
    public boolean isValid(boolean condition) {
        return condition && condition;
    }

    public String getPassword() {
        return DB_PASSWORD;
    }

}
