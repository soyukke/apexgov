package apexemu.runtime;

public final class Decimal {
  private Decimal() {}

  public static Double valueOf(String value) {
    if (value == null || value.isBlank()) {
      return 0.0;
    }
    return Double.valueOf(value.trim());
  }
}
