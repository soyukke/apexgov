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

  public static void isInstanceOfType(Object instance, Object expectedType) {
    isInstanceOfType(instance, expectedType, null);
  }

  public static void isInstanceOfType(Object instance, Object expectedType, String message) {
    if (!isInstanceMatch(instance, expectedType)) {
      SystemAssert.fail(
          defaultMessage(
              "Expected instance of <" + describeExpectedType(expectedType) + "> but was <"
                  + describeInstanceType(instance)
                  + ">",
              message));
    }
  }

  public static void isNotInstanceOfType(Object instance, Object notExpectedType) {
    isNotInstanceOfType(instance, notExpectedType, null);
  }

  public static void isNotInstanceOfType(Object instance, Object notExpectedType, String message) {
    if (isInstanceMatch(instance, notExpectedType)) {
      SystemAssert.fail(
          defaultMessage(
              "Expected value not to be instance of <"
                  + describeExpectedType(notExpectedType)
                  + "> but was <"
                  + describeInstanceType(instance)
                  + ">",
              message));
    }
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

  private static boolean isInstanceMatch(Object instance, Object expectedType) {
    if (instance == null || expectedType == null) {
      return false;
    }

    if (expectedType instanceof Class<?> expectedClass) {
      if (expectedClass.isInstance(instance)) {
        return true;
      }
      if (instance instanceof ApexSObject row) {
        String simpleName = expectedClass.getSimpleName();
        String canonicalName = expectedClass.getName();
        return row.type().equalsIgnoreCase(simpleName) || row.type().equalsIgnoreCase(canonicalName);
      }
      return false;
    }

    final String expectedTypeName;
    if (expectedType instanceof String raw) {
      expectedTypeName = raw.trim();
    } else if (expectedType instanceof ApexSObject rowType) {
      expectedTypeName = rowType.type();
    } else {
      expectedTypeName = String.valueOf(expectedType).trim();
    }
    if (expectedTypeName.isEmpty()) {
      return false;
    }

    if (instance instanceof ApexSObject row) {
      return row.type().equalsIgnoreCase(expectedTypeName);
    }

    Class<?> actualClass = instance.getClass();
    return typeHierarchyMatches(actualClass, expectedTypeName);
  }

  private static boolean typeHierarchyMatches(Class<?> actualClass, String expectedTypeName) {
    for (Class<?> current = actualClass; current != null; current = current.getSuperclass()) {
      if (typeNameMatches(current, expectedTypeName)) {
        return true;
      }
      for (Class<?> iface : current.getInterfaces()) {
        if (interfaceHierarchyMatches(iface, expectedTypeName)) {
          return true;
        }
      }
      for (Class<?> nested : current.getDeclaredClasses()) {
        if (nested == null) {
          continue;
        }
        if (typeNameMatches(nested, expectedTypeName)) {
          return true;
        }
      }
    }
    return false;
  }

  private static boolean interfaceHierarchyMatches(Class<?> iface, String expectedTypeName) {
    if (iface == null) {
      return false;
    }
    if (typeNameMatches(iface, expectedTypeName)) {
      return true;
    }
    for (Class<?> parent : iface.getInterfaces()) {
      if (interfaceHierarchyMatches(parent, expectedTypeName)) {
        return true;
      }
    }
    return false;
  }

  private static boolean typeNameMatches(Class<?> type, String expectedTypeName) {
    if (type == null || expectedTypeName == null || expectedTypeName.isEmpty()) {
      return false;
    }
    return type.getSimpleName().equalsIgnoreCase(expectedTypeName)
        || type.getName().equalsIgnoreCase(expectedTypeName)
        || type.getName().endsWith("$" + expectedTypeName)
        || type.getName().endsWith("." + expectedTypeName);
  }

  private static String describeExpectedType(Object expectedType) {
    if (expectedType == null) {
      return "null";
    }
    if (expectedType instanceof Class<?> clazz) {
      return clazz.getName();
    }
    if (expectedType instanceof ApexSObject rowType) {
      return rowType.type();
    }
    String text = String.valueOf(expectedType).trim();
    return text.isEmpty() ? "unknown" : text;
  }

  private static String describeInstanceType(Object instance) {
    if (instance == null) {
      return "null";
    }
    if (instance instanceof ApexSObject row) {
      return row.type();
    }
    return instance.getClass().getName();
  }

  private static String defaultMessage(String fallback, String message) {
    return message == null || message.isBlank() ? fallback : message;
  }
}
