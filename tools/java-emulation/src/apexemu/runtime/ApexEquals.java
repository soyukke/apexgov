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
    if (a == null || b == null) return false;
    // Handle numeric cross-type comparison (Integer == Long, etc.)
    if (a instanceof Number && b instanceof Number) {
      return ((Number) a).doubleValue() == ((Number) b).doubleValue();
    }
    return a.equals(b);
  }

  /** Null-safe value inequality, matching Apex != semantics. */
  public static boolean ne(Object a, Object b) {
    return !eq(a, b);
  }
}
