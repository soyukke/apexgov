package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public final class OrgLimits {
  private OrgLimits() {}

  public static Map<String, System.OrgLimit> getMap() {
    Map<String, System.OrgLimit> limits = new LinkedHashMap<>();
    limits.put("SingleEmail", new System.OrgLimit(5000, 0));
    limits.put("DailyApiRequests", new System.OrgLimit(100000, 0));
    return limits;
  }
}
