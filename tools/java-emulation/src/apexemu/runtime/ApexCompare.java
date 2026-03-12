package apexemu.runtime;

/**
 * Null-safe comparison utilities that match Apex semantics.
 * In Apex, comparisons involving null always return false
 * (except null == null which returns true).
 */
public final class ApexCompare {
  private ApexCompare() {}

  /** Returns true iff a &gt; b; returns false if a is null. */
  public static boolean gt(Integer a, int b) { return a != null && a > b; }
  public static boolean gt(Long a, long b) { return a != null && a > b; }
  public static boolean gt(Double a, double b) { return a != null && a > b; }
  public static boolean gt(Object a, Object b) { if (a == null || b == null) return false; return cmp(a, b) > 0; }
  public static boolean gt(Object a, Object b, String message) { return gt(a, b); }

  /** Returns true iff a &lt; b; returns false if a is null. */
  public static boolean lt(Integer a, int b) { return a != null && a < b; }
  public static boolean lt(Long a, long b) { return a != null && a < b; }
  public static boolean lt(Double a, double b) { return a != null && a < b; }
  public static boolean lt(Object a, Object b) { if (a == null || b == null) return false; return cmp(a, b) < 0; }
  public static boolean lt(Object a, Object b, String message) { return lt(a, b); }

  /** Returns true iff a &gt;= b; returns false if a is null. */
  public static boolean gte(Integer a, int b) { return a != null && a >= b; }
  public static boolean gte(Long a, long b) { return a != null && a >= b; }
  public static boolean gte(Double a, double b) { return a != null && a >= b; }
  public static boolean gte(Object a, Object b) { if (a == null || b == null) return false; return cmp(a, b) >= 0; }
  public static boolean gte(Object a, Object b, String message) { return gte(a, b); }

  /** Returns true iff a &lt;= b; returns false if a is null. */
  public static boolean lte(Integer a, int b) { return a != null && a <= b; }
  public static boolean lte(Long a, long b) { return a != null && a <= b; }
  public static boolean lte(Double a, double b) { return a != null && a <= b; }
  public static boolean lte(Object a, Object b) { if (a == null || b == null) return false; return cmp(a, b) <= 0; }
  public static boolean lte(Object a, Object b, String message) { return lte(a, b); }

  @SuppressWarnings({"unchecked", "rawtypes"})
  private static int cmp(Object a, Object b) {
    if (a == null || b == null) return a == b ? 0 : (a == null ? -1 : 1);
    if (a instanceof Comparable ca && b instanceof Comparable) {
      try { return ca.compareTo(b); } catch (ClassCastException e) { return 0; }
    }
    return 0;
  }

  public static DateTime castDateTime(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof DateTime dateTime) {
      return dateTime;
    }
    throw new System.TypeException(
        "Invalid conversion from runtime type "
            + value.getClass().getSimpleName()
            + " to Datetime");
  }
}
