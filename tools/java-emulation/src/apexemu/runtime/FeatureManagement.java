package apexemu.runtime;

public final class FeatureManagement {
  private FeatureManagement() {}

  public static boolean checkPermission(String permissionName) {
    if (permissionName == null || permissionName.isBlank()) {
      return false;
    }
    return false;
  }
}
