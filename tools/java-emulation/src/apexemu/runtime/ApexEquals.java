package apexemu.runtime;

import java.util.Objects;

/**
 * Apex-style equality comparison.
 * In Apex, == and != are value-based (like Java's .equals()) and null-safe.
 * This class provides null-safe value comparison to match Apex semantics.
 */
public final class ApexEquals {
  private ApexEquals() {}

  /** Null-safe value equality, matching Apex == semantics. */
  public static boolean eq(Object a, Object b) {
    if (a == b) return true;
    // Apex treats null and empty string as equal
    if (a == null && b instanceof String s && s.isEmpty()) return true;
    if (b == null && a instanceof String s && s.isEmpty()) return true;
    if (a == null || b == null) return false;
    // Handle numeric cross-type comparison (Integer == Long, etc.)
    if (a instanceof Number && b instanceof Number) {
      return ((Number) a).doubleValue() == ((Number) b).doubleValue();
    }
    // Handle Date/DateTime/String cross-type comparison (Apex compares by value)
    if (a instanceof Date && b instanceof String) {
      return a.toString().equals(b);
    }
    if (b instanceof Date && a instanceof String) {
      return b.toString().equals(a);
    }
    if (a instanceof DateTime && b instanceof String) {
      return a.toString().equals(b);
    }
    if (b instanceof DateTime && a instanceof String) {
      return b.toString().equals(a);
    }
    return a.equals(b);
  }

  /** Null-safe value inequality, matching Apex != semantics. */
  public static boolean ne(Object a, Object b) {
    return !eq(a, b);
  }
}
