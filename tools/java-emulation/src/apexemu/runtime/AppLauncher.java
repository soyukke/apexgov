package apexemu.runtime;

import java.util.ArrayList;
import java.util.List;

public final class AppLauncher {
  private AppLauncher() {}

  public static final class AppMenu {
    private static final ThreadLocal<List<String>> ORG_SORT_ORDER =
        ThreadLocal.withInitial(ArrayList::new);

    private AppMenu() {}

    public static void setOrgSortOrder(List<String> orderedItems) {
      if (orderedItems == null) {
        ORG_SORT_ORDER.set(new ArrayList<>());
        return;
      }
      ORG_SORT_ORDER.set(new ArrayList<>(orderedItems));
    }

    public static List<String> getOrgSortOrder() {
      return new ArrayList<>(ORG_SORT_ORDER.get());
    }
  }
}
