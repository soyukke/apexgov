package apexemu.runtime;

public final class ApexSwitch {
  private ApexSwitch() {}

  public static String typeName(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof ApexSObject row) {
      String type = row.type();
      if (type != null && !type.isBlank()) {
        return type;
      }
    }
    return String.valueOf(value);
  }
}
