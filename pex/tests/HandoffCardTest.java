import storm.pex.HandoffCard;

public class HandoffCardTest {
    private static void rejected(String storm, String groups) {
        try { HandoffCard.render(storm, groups); }
        catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Accepted invalid handoff");
    }

    public static void main(String[] args) {
        String card = HandoffCard.render("A2", "5:5,6;9:9");
        if (!card.equals("Storm A2\nRoot Managed Alert #5; group Managed Alert IDs: 5,6\nRoot Managed Alert #9; group Managed Alert IDs: 9"))
            throw new AssertionError(card);
        if (!card.equals(HandoffCard.render("A2", "5:5,6;9:9"))) throw new AssertionError("Nondeterministic");
        rejected(null, "5:5");
        rejected("../A2", "5:5");
        rejected("A2", null);
        rejected("A2", "");
        rejected("A2", "5:5;");
        rejected("A2", "5:5\n6");
        rejected("A2", "0:0");
        rejected("A2", "5:6,x");
        rejected("A2", "5:0005");
        rejected("A2", "5:6".repeat(700));
        rejected("A2", ("5:5;".repeat(32)) + "5:5");
        rejected("A2", ("5:" + "5,".repeat(64)) + "5");
        System.out.println("Java 11-compatible formatter: 14 checks PASS");
    }
}
