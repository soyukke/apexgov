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
    // Apex == on Strings is case-insensitive
    if (a instanceof String sa && b instanceof String sb) {
      return sa.equalsIgnoreCase(sb);
    }
    // Apex == on enums is case-insensitive (e.g. Succeeded == SUCCEEDED)
    if (a instanceof Enum<?> ea && b instanceof Enum<?> eb) {
      if (ea.getDeclaringClass() == eb.getDeclaringClass()) {
        return ea == eb || ea.name().equalsIgnoreCase(eb.name());
      }
    }
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
      return normalizeDateTimeString(a.toString()).equals(normalizeDateTimeString((String) b));
    }
    if (b instanceof DateTime && a instanceof String) {
      return normalizeDateTimeString(b.toString()).equals(normalizeDateTimeString((String) a));
    }
    return a.equals(b);
  }

  /** Normalize DateTime strings: remove trailing .000 millis for comparison. */
  private static String normalizeDateTimeString(String s) {
    if (s != null && s.endsWith(".000Z")) {
      return s.substring(0, s.length() - 5) + "Z";
    }
    return s;
  }

  /** Null-safe value inequality, matching Apex != semantics. */
  public static boolean ne(Object a, Object b) {
    return !eq(a, b);
  }
}
