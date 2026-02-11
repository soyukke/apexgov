package apexemu.runtime;

public final class ApexAssert {
  private ApexAssert() {}

  public static void isTrue(boolean value) {
    isTrue(value, null);
  }

  public static void isTrue(boolean value, String message) {
    SystemAssert.assertTrue(value, message);
  }

  public static void isFalse(boolean value) {
    isFalse(value, null);
  }

  public static void isFalse(boolean value, String message) {
    SystemAssert.assertFalse(value, message);
  }

  public static void areEqual(Object expected, Object actual) {
    areEqual(expected, actual, null);
  }

  public static void areEqual(Object expected, Object actual, String message) {
    SystemAssert.assertEquals(expected, actual, message);
  }

  public static void areNotEqual(Object expected, Object actual) {
    areNotEqual(expected, actual, null);
  }

  public static void areNotEqual(Object expected, Object actual, String message) {
    SystemAssert.assertNotEquals(expected, actual, message);
  }

  public static void isNull(Object value) {
    isNull(value, null);
  }

  public static void isNull(Object value, String message) {
    SystemAssert.assertNull(value, message);
  }

  public static void isNotNull(Object value) {
    isNotNull(value, null);
  }

  public static void isNotNull(Object value, String message) {
    SystemAssert.assertNotNull(value, message);
  }

  public static void fail() {
    fail("Assertion failed");
  }

  public static void fail(String message) {
    SystemAssert.fail(message);
  }

  public static void equalsInt(int expected, int actual, String message) {
    areEqual(expected, actual, message);
  }

  public static void equalsLong(long expected, long actual, String message) {
    areEqual(expected, actual, message);
  }
}
