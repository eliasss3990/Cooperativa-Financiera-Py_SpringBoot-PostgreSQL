package developers;

public class BadService {

    private String getNullValue() {
        return null;
    }

    // SonarCloud java:S2259 — null pointer dereference garantizado (bug)
    public int calculateLength() {
        return getNullValue().length();
    }

}
