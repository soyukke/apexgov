package apexemu.runtime;

import java.util.ArrayList;
import java.util.List;

public final class SystemAssert {
  private SystemAssert() {}

  public record AssertionEntry(String method, String detail, boolean passed, String location) {}

  private static final ThreadLocal<List<AssertionEntry>> LOG = ThreadLocal.withInitial(ArrayList::new);

  public static List<AssertionEntry> drainLog() {
    List<AssertionEntry> entries = new ArrayList<>(LOG.get());
    LOG.get().clear();
    return entries;
  }

  private static void log(String method, String detail, boolean passed) {
    LOG.get().add(new AssertionEntry(method, detail, passed, callerLocation()));
  }

  private static String callerLocation() {
    StackTraceElement[] trace = Thread.currentThread().getStackTrace();
    for (StackTraceElement frame : trace) {
      String className = frame.getClassName();
      if (className.startsWith("java.") || className.startsWith("jdk.") || className.startsWith("sun.")) {
        continue;
      }
      if (className.startsWith("apexemu.runner.") || className.startsWith("apexemu.runtime.")) {
        continue;
      }
      String fileName = frame.getFileName();
      int line = frame.getLineNumber();
      if (fileName != null && line > 0) {
        return fileName + ":" + line;
      }
      return frame.toString();
    }
    return null;
  }

  public static void assertTrue(boolean value) {
    assertTrue(value, null);
  }

  public static void assertTrue(boolean value, String message) {
    log("assertTrue", "Expected true", value);
    if (!value) {
      fail(defaultMessage("Expected true", message));
    }
  }

  public static void assertTrue(boolean value, Object message) {
    assertTrue(value, message == null ? null : String.valueOf(message));
  }

  public static void assertTrue(boolean expected, boolean actual) {
    assertEquals(expected, actual, null);
  }

  public static void assertFalse(boolean value) {
    assertFalse(value, null);
  }

  public static void assertFalse(boolean value, String message) {
    log("assertFalse", "Expected false", !value);
    if (value) {
      fail(defaultMessage("Expected false", message));
    }
  }

  public static void assertFalse(boolean value, Object message) {
    assertFalse(value, message == null ? null : String.valueOf(message));
  }

  public static void assertEquals(Object expected, Object actual) {
    assertEquals(expected, actual, null);
  }

  public static void assertEquals(Object expected, Object actual, String message) {
    boolean passed = ApexEquals.eq(expected, actual);
    log("assertEquals", "Expected <" + String.valueOf(expected) + "> == <" + String.valueOf(actual) + ">", passed);
    if (!passed) {
      fail(
          defaultMessage(
              "Expected <" + String.valueOf(expected) + "> but was <" + String.valueOf(actual) + ">",
              message));
    }
  }

  public static void assertEquals(Object expected, Object actual, Object message) {
    assertEquals(expected, actual, message == null ? null : String.valueOf(message));
  }

  public static void assertNotEquals(Object expected, Object actual) {
    assertNotEquals(expected, actual, null);
  }

  public static void assertNotEquals(Object expected, Object actual, String message) {
    boolean passed = ApexEquals.ne(expected, actual);
    log("assertNotEquals", "Expected <" + String.valueOf(expected) + "> != <" + String.valueOf(actual) + ">", passed);
    if (!passed) {
      fail(defaultMessage("Values should not be equal: <" + String.valueOf(actual) + ">", message));
    }
  }

  public static void assertNull(Object value) {
    assertNull(value, null);
  }

  public static void assertNull(Object value, String message) {
    boolean passed = (value == null);
    log("assertNull", "Expected null, got <" + String.valueOf(value) + ">", passed);
    if (!passed) {
      fail(defaultMessage("Expected null but was <" + String.valueOf(value) + ">", message));
    }
  }

  public static void assertNotNull(Object value) {
    assertNotNull(value, null);
  }

  public static void assertNotNull(Object value, String message) {
    boolean passed = (value != null);
    log("assertNotNull", "Expected non-null", passed);
    if (!passed) {
      fail(defaultMessage("Expected non-null value", message));
    }
  }

  public static void fail(String message) {
    log("fail", message == null ? "Assertion failed" : message, false);
    throw new AssertionError(message == null || message.isBlank() ? "Assertion failed" : message);
  }

  private static String defaultMessage(String fallback, String message) {
    return (message == null || message.isBlank()) ? fallback : message;
  }
}
