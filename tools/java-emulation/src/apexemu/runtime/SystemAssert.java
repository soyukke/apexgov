package apexemu.runtime;

import java.util.Objects;

public final class SystemAssert {
  private SystemAssert() {}

  public static void assertTrue(boolean value) {
    assertTrue(value, null);
  }

  public static void assertTrue(boolean value, String message) {
    if (!value) {
      fail(defaultMessage("Expected true", message));
    }
  }

  public static void assertFalse(boolean value) {
    assertFalse(value, null);
  }

  public static void assertFalse(boolean value, String message) {
    if (value) {
      fail(defaultMessage("Expected false", message));
    }
  }

  public static void assertEquals(Object expected, Object actual) {
    assertEquals(expected, actual, null);
  }

  public static void assertEquals(Object expected, Object actual, String message) {
    if (!Objects.equals(expected, actual)) {
      fail(
          defaultMessage(
              "Expected <" + String.valueOf(expected) + "> but was <" + String.valueOf(actual) + ">",
              message));
    }
  }

  public static void assertNotEquals(Object expected, Object actual) {
    assertNotEquals(expected, actual, null);
  }

  public static void assertNotEquals(Object expected, Object actual, String message) {
    if (Objects.equals(expected, actual)) {
      fail(defaultMessage("Values should not be equal: <" + String.valueOf(actual) + ">", message));
    }
  }

  public static void assertNull(Object value) {
    assertNull(value, null);
  }

  public static void assertNull(Object value, String message) {
    if (value != null) {
      fail(defaultMessage("Expected null but was <" + String.valueOf(value) + ">", message));
    }
  }

  public static void assertNotNull(Object value) {
    assertNotNull(value, null);
  }

  public static void assertNotNull(Object value, String message) {
    if (value == null) {
      fail(defaultMessage("Expected non-null value", message));
    }
  }

  public static void fail(String message) {
    throw new AssertionError(message == null || message.isBlank() ? "Assertion failed" : message);
  }

  private static String defaultMessage(String fallback, String message) {
    return (message == null || message.isBlank()) ? fallback : message;
  }
}
