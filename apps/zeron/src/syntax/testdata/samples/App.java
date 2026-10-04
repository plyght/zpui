package demo;
import java.util.List;
/** Javadoc */
@FunctionalInterface
public class App<T extends Comparable<T>> implements Runnable {
    private static final int MAX = 10;
    private final List<T> items;
    public App(List<T> items) { this.items = items; }
    @Override
    public void run() {
        for (int i = 0; i < MAX; i++) {
            System.out.println("item " + i + 'c' + 1.5f + true + null);
        }
        items.stream().map(x -> x.toString()).forEach(System.out::println);
    }
}
