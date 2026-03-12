package apexemu.runtime;

import java.util.Map;

public final class SfdoLogUtils {
  private SfdoLogUtils() {}

  public static void log(
      String featureName, String componentName, String actionName, Map<?, ?> context) {}

  public static void log(
      Object featureName, Object componentName, Object actionName, Map<?, ?> context) {}

  public static void log(
      String featureName,
      String componentName,
      String actionName,
      Map<?, ?> context,
      Integer value) {}

  public static void log(
      Object featureName, Object componentName, Object actionName, Map<?, ?> context, Integer value) {}

  public static void log(
      String featureName,
      String componentName,
      String actionName,
      Map<?, ?> context,
      int value) {}

  public static void log(
      Object featureName, Object componentName, Object actionName, Map<?, ?> context, int value) {}
}
