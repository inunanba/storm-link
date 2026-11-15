package storm.pex;

/** Formats only immutable Managed Alert references, never raw alert/model text. */
public final class HandoffCard {
    private HandoffCard() {}

    public static String render(String storm, String groups) {
        if (storm == null || !storm.matches("[A-Za-z0-9_-]{1,64}") ||
            groups == null || groups.isEmpty() || groups.length() > 2048)
            throw new IllegalArgumentException("Invalid handoff input");
        String[] rows = groups.split(";", -1);
        if (rows.length > 32) throw new IllegalArgumentException("Too many groups");
        StringBuilder card = new StringBuilder("Storm ").append(storm);
        for (String row : rows) {
            if (!row.matches("[1-9][0-9]{0,17}:([1-9][0-9]{0,17})(,[1-9][0-9]{0,17}){0,63}"))
                throw new IllegalArgumentException("Invalid Managed Alert reference");
            int sep = row.indexOf(':');
            card.append("\nRoot Managed Alert #").append(row, 0, sep)
                .append("; group Managed Alert IDs: ").append(row, sep + 1, row.length());
        }
        return card.toString();
    }
}
