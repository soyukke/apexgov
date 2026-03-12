package apexemu.runtime;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public final class FeatureManagement {
  private FeatureManagement() {}

  private static final Map<String, Boolean> packageBooleans = new ConcurrentHashMap<>();
  private static final Map<String, Integer> packageIntegers = new ConcurrentHashMap<>();
  private static final Map<String, Date> packageDates = new ConcurrentHashMap<>();

  public static boolean checkPermission(String permissionName) {
    if (permissionName == null || permissionName.isBlank()) {
      return false;
    }
    return false;
  }

  public static boolean checkPackageBooleanValue(String apiName) {
    if (apiName != null && packageBooleans.containsKey(apiName)) {
      return Boolean.TRUE.equals(packageBooleans.get(apiName));
    }
    return checkPermission(apiName);
  }

  public static void setPackageBooleanValue(String apiName, Boolean value) {
    if (apiName == null || apiName.isBlank()) {
      return;
    }
    packageBooleans.put(apiName, Boolean.TRUE.equals(value));
  }

  public static Integer checkPackageIntegerValue(String apiName) {
    if (apiName == null || apiName.isBlank()) {
      return null;
    }
    return packageIntegers.get(apiName);
  }

  public static void setPackageIntegerValue(String apiName, Integer value) {
    if (apiName == null || apiName.isBlank()) {
      return;
    }
    packageIntegers.put(apiName, value);
  }

  public static Date checkPackageDateValue(String apiName) {
    if (apiName == null || apiName.isBlank()) {
      return null;
    }
    return packageDates.get(apiName);
  }

  public static void setPackageDateValue(String apiName, Date value) {
    if (apiName == null || apiName.isBlank()) {
      return;
    }
    packageDates.put(apiName, value);
  }
}
