package apexemu.runtime;

import java.lang.reflect.Array;
import java.util.Map;
import java.util.StringJoiner;

public final class ApexStrings {
  private ApexStrings() {}

  public static boolean isBlank(String value) {
    return value == null || value.trim().isEmpty();
  }

  public static boolean isNotBlank(String value) {
    return !isBlank(value);
  }

  public static boolean isEmpty(String value) {
    return value == null || value.isEmpty();
  }

  public static boolean isNotEmpty(String value) {
    return !isEmpty(value);
  }

  public static String escapeSingleQuotes(String value) {
    if (value == null) {
      return null;
    }
    return value.replace("'", "\\'");
  }

  public static String join(Object values, String separator) {
    String sep = separator == null ? "" : separator;
    if (values == null) {
      return "";
    }
    if (values instanceof Iterable<?> iterable) {
      return joinIterable(iterable, sep);
    }
    if (values instanceof Map<?, ?> map) {
      return joinIterable(map.values(), sep);
    }
    Class<?> type = values.getClass();
    if (type.isArray()) {
      return joinArray(values, sep);
    }
    return String.valueOf(values);
  }

  private static String joinIterable(Iterable<?> values, String separator) {
    StringJoiner joiner = new StringJoiner(separator);
    for (Object value : values) {
      joiner.add(value == null ? "" : String.valueOf(value));
    }
    return joiner.toString();
  }

  private static String joinArray(Object values, String separator) {
    int length = Array.getLength(values);
    StringJoiner joiner = new StringJoiner(separator);
    for (int i = 0; i < length; i++) {
      Object value = Array.get(values, i);
      joiner.add(value == null ? "" : String.valueOf(value));
    }
    return joiner.toString();
  }
}
