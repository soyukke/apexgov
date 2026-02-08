package apexemu.runtime;

public final class ApexAssert {
  private ApexAssert() {}

  public static void isTrue(boolean value, String message) {
    SystemAssert.assertTrue(value, message);
  }

  public static void equalsInt(int expected, int actual, String message) {
    SystemAssert.assertEquals(expected, actual, message);
  }

  public static void equalsLong(long expected, long actual, String message) {
    SystemAssert.assertEquals(expected, actual, message);
  }
}
