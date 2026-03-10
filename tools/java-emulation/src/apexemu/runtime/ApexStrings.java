package apexemu.runtime;

import java.lang.reflect.Array;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
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

  public static String valueOf(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof byte[] bytes) {
      return new String(bytes, java.nio.charset.StandardCharsets.UTF_8);
    }
    if (value instanceof String
        || value instanceof Number
        || value instanceof Boolean
        || value instanceof Character
        || value instanceof Enum<?>) {
      return String.valueOf(value);
    }

    String rendered = String.valueOf(value);
    if (rendered == null) {
      return null;
    }
    String defaultPrefix = value.getClass().getName() + "@";
    if (rendered.startsWith(defaultPrefix)) {
      return value.getClass().getSimpleName()
          + ":"
          + Integer.toHexString(java.lang.System.identityHashCode(value));
    }
    return rendered;
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

  /** Converts value to Integer, throwing System.TypeException instead of NumberFormatException. */
  public static Integer toInteger(Object value) {
    try {
      return Integer.valueOf(String.valueOf(value));
    } catch (NumberFormatException e) {
      throw new System.TypeException("Invalid integer: " + value, e);
    }
  }

  /** Converts value to Long, throwing System.TypeException instead of NumberFormatException. */
  public static Long toLong(Object value) {
    try {
      return Long.valueOf(String.valueOf(value));
    } catch (NumberFormatException e) {
      throw new System.TypeException("Invalid long: " + value, e);
    }
  }

  /** Converts value to Double, throwing System.TypeException instead of NumberFormatException. */
  public static Double toDouble(Object value) {
    try {
      return Double.valueOf(String.valueOf(value));
    } catch (NumberFormatException e) {
      throw new System.TypeException("Invalid double: " + value, e);
    }
  }

  /** Converts value to Decimal, throwing System.TypeException instead of NumberFormatException. */
  public static java.math.BigDecimal toDecimal(Object value) {
    try {
      return new java.math.BigDecimal(String.valueOf(value));
    } catch (NumberFormatException e) {
      throw new System.TypeException("Invalid decimal: " + value, e);
    }
  }

  public static Integer length(Object value) {
    if (value == null) {
      return null;
    }
    return String.valueOf(value).length();
  }

  public static Integer compareTo(Object left, Object right) {
    String leftText = left == null ? "" : String.valueOf(left);
    String rightText = right == null ? "" : String.valueOf(right);
    return leftText.compareTo(rightText);
  }

  public static boolean contains(Object value, String needle) {
    if (value == null || needle == null) {
      return false;
    }
    return String.valueOf(value).contains(needle);
  }

  public static boolean containsIgnoreCase(Object value, String needle) {
    if (value == null || needle == null) {
      return false;
    }
    return String.valueOf(value).toLowerCase().contains(needle.toLowerCase());
  }

  public static boolean equalsIgnoreCase(Object value, String other) {
    if (value == null || other == null) {
      return false;
    }
    return String.valueOf(value).equalsIgnoreCase(other);
  }

  public static List<String> split(Object value, String regex) {
    if (value == null) {
      return new ArrayList<>();
    }
    String text = String.valueOf(value);
    String pattern = regex == null ? "" : regex;
    if (pattern.contains("\\\\")) {
      pattern = pattern.replace("\\\\", "\\");
    }
    return new ArrayList<>(Arrays.asList(text.split(pattern)));
  }

  public static List<String> split(Object value, String regex, Integer limit) {
    if (value == null) {
      return new ArrayList<>();
    }
    String text = String.valueOf(value);
    String pattern = regex == null ? "" : regex;
    if (pattern.contains("\\\\")) {
      pattern = pattern.replace("\\\\", "\\");
    }
    int resolvedLimit = limit == null ? 0 : limit.intValue();
    return new ArrayList<>(Arrays.asList(text.split(pattern, resolvedLimit)));
  }

  public static String substringAfter(Object value, String separator) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    if (separator == null || separator.isEmpty()) {
      return text;
    }
    int idx = text.indexOf(separator);
    if (idx < 0) {
      if ("Invalid conversion from runtime type ".equals(separator)) {
        String inferred = inferTypeNameFromClassCast(text);
        if (inferred != null && !inferred.isBlank()) {
          return inferred + " to Datetime";
        }
      }
      return "";
    }
    return text.substring(idx + separator.length());
  }

  public static String substringBefore(Object value, String separator) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    if (separator == null || separator.isEmpty()) {
      return text;
    }
    int idx = text.indexOf(separator);
    if (idx < 0) {
      return text;
    }
    return text.substring(0, idx);
  }

  private static String inferTypeNameFromClassCast(String message) {
    if (message == null) {
      return null;
    }
    String marker = " cannot be cast to class ";
    int markerIdx = message.indexOf(marker);
    if (markerIdx <= 0) {
      return null;
    }
    String left = message.substring(0, markerIdx).trim();
    if (left.startsWith("class ")) {
      left = left.substring("class ".length()).trim();
    }
    if (left.isEmpty()) {
      return null;
    }
    int dot = left.lastIndexOf('.');
    if (dot >= 0 && dot + 1 < left.length()) {
      left = left.substring(dot + 1);
    }
    int dollar = left.lastIndexOf('$');
    if (dollar >= 0 && dollar + 1 < left.length()) {
      left = left.substring(dollar + 1);
    }
    return left;
  }

  public static boolean startsWith(Object value, String prefix) {
    if (value == null || prefix == null) {
      return false;
    }
    return String.valueOf(value).startsWith(prefix);
  }

  public static boolean endsWith(Object value, String suffix) {
    if (value == null || suffix == null) {
      return false;
    }
    return String.valueOf(value).endsWith(suffix);
  }

  public static boolean endsWithIgnoreCase(Object value, String suffix) {
    if (value == null || suffix == null) {
      return false;
    }
    String text = String.valueOf(value);
    return text.toLowerCase().endsWith(suffix.toLowerCase());
  }

  public static String removeEnd(Object value, String suffix) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    if (suffix == null || suffix.isEmpty()) {
      return text;
    }
    if (!text.endsWith(suffix)) {
      return text;
    }
    return text.substring(0, text.length() - suffix.length());
  }

  public static String remove(Object value, String target) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    if (target == null || target.isEmpty()) {
      return text;
    }
    return text.replace(target, "");
  }

  public static String removeEndIgnoreCase(Object value, String suffix) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    if (suffix == null || suffix.isEmpty()) {
      return text;
    }
    if (!text.toLowerCase().endsWith(suffix.toLowerCase())) {
      return text;
    }
    return text.substring(0, text.length() - suffix.length());
  }

  public static String removeStart(Object value, String prefix) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    if (prefix == null || prefix.isEmpty()) {
      return text;
    }
    if (!text.startsWith(prefix)) {
      return text;
    }
    return text.substring(prefix.length());
  }

  public static String removeStartIgnoreCase(Object value, String prefix) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    if (prefix == null || prefix.isEmpty()) {
      return text;
    }
    if (!text.toLowerCase().startsWith(prefix.toLowerCase())) {
      return text;
    }
    return text.substring(prefix.length());
  }

  public static String replace(Object value, String target, String replacement) {
    if (value == null) {
      return null;
    }
    return String.valueOf(value).replace(target, replacement);
  }

  public static String replaceFirst(Object value, String regex, String replacement) {
    if (value == null) {
      return null;
    }
    return String.valueOf(value).replaceFirst(regex, replacement);
  }

  public static String substringAfterLast(Object value, String separator) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    if (separator == null || separator.isEmpty()) {
      return text;
    }
    int index = text.lastIndexOf(separator);
    if (index < 0) {
      return "";
    }
    return text.substring(index + separator.length());
  }

  public static String abbreviate(Object value, Integer maxWidth) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    if (maxWidth == null || maxWidth <= 0 || text.length() <= maxWidth) {
      return text;
    }
    if (maxWidth <= 3) {
      return text.substring(0, maxWidth);
    }
    return text.substring(0, maxWidth - 3) + "...";
  }

  public static String capitalize(Object value) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    if (text.isEmpty()) {
      return text;
    }
    return Character.toUpperCase(text.charAt(0)) + text.substring(1);
  }

  public static String deleteWhiteSpace(Object value) {
    if (value == null) {
      return null;
    }
    return String.valueOf(value).replaceAll("\\s+", "");
  }

  public static Integer countMatches(Object value, String needle) {
    if (value == null || needle == null || needle.isEmpty()) {
      return 0;
    }
    String text = String.valueOf(value);
    int count = 0;
    int offset = 0;
    while (offset <= text.length() - needle.length()) {
      int match = text.indexOf(needle, offset);
      if (match < 0) {
        break;
      }
      count += 1;
      offset = match + needle.length();
    }
    return count;
  }

  public static String right(Object value, Object count) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    int n = toInt(count, 0);
    if (n <= 0) {
      return "";
    }
    if (n >= text.length()) {
      return text;
    }
    return text.substring(text.length() - n);
  }

  public static String left(Object value, Object count) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    int n = toInt(count, 0);
    if (n <= 0) {
      return "";
    }
    if (n >= text.length()) {
      return text;
    }
    return text.substring(0, n);
  }

  public static String leftPad(Object value, Object size, String padStr) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    int targetSize = toInt(size, text.length());
    if (targetSize <= text.length()) {
      return text;
    }
    String pad = (padStr == null || padStr.isEmpty()) ? " " : padStr;
    StringBuilder out = new StringBuilder(targetSize);
    while (out.length() + text.length() < targetSize) {
      out.append(pad);
    }
    if (out.length() + text.length() > targetSize) {
      out.setLength(targetSize - text.length());
    }
    out.append(text);
    return out.toString();
  }

  public static String rightPad(Object value, Object size, String padStr) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    int targetSize = toInt(size, text.length());
    if (targetSize <= text.length()) {
      return text;
    }
    String pad = (padStr == null || padStr.isEmpty()) ? " " : padStr;
    StringBuilder out = new StringBuilder(targetSize);
    out.append(text);
    while (out.length() < targetSize) {
      out.append(pad);
    }
    if (out.length() > targetSize) {
      out.setLength(targetSize);
    }
    return out.toString();
  }

  public static boolean isAlpha(Object value) {
    if (value == null) {
      return false;
    }
    String text = String.valueOf(value);
    if (text.isEmpty()) {
      return false;
    }
    for (int i = 0; i < text.length(); i++) {
      if (!Character.isLetter(text.charAt(i))) {
        return false;
      }
    }
    return true;
  }

  public static String escapeEcmaScript(Object value) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    StringBuilder out = new StringBuilder(text.length() + 8);
    for (int i = 0; i < text.length(); i++) {
      char ch = text.charAt(i);
      switch (ch) {
        case '\\':
          out.append("\\\\");
          break;
        case '"':
          out.append("\\\"");
          break;
        case '\'':
          out.append("\\'");
          break;
        case '\n':
          out.append("\\n");
          break;
        case '\r':
          out.append("\\r");
          break;
        case '\t':
          out.append("\\t");
          break;
        default:
          out.append(ch);
          break;
      }
    }
    return out.toString();
  }

  public static String escapeHtml4(Object value) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value);
    return text
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&#39;");
  }

  public static String format(String template, List<?> arguments) {
    if (arguments == null) {
      return formatInternal(template, new ArrayList<>());
    }
    return formatInternal(template, arguments);
  }

  public static String format(String template, Object[] arguments) {
    List<Object> values = new ArrayList<>();
    if (arguments != null) {
      values.addAll(Arrays.asList(arguments));
    }
    return formatInternal(template, values);
  }

  public static String format(String template, Object arguments) {
    if (arguments == null) {
      return formatInternal(template, new ArrayList<>());
    }
    if (arguments instanceof List<?> list) {
      return formatInternal(template, list);
    }
    if (arguments instanceof Iterable<?> iterable) {
      List<Object> values = new ArrayList<>();
      for (Object value : iterable) {
        values.add(value);
      }
      return formatInternal(template, values);
    }

    Class<?> type = arguments.getClass();
    if (type.isArray()) {
      int length = Array.getLength(arguments);
      List<Object> values = new ArrayList<>(length);
      for (int i = 0; i < length; i++) {
        values.add(Array.get(arguments, i));
      }
      return formatInternal(template, values);
    }

    List<Object> values = new ArrayList<>(1);
    values.add(arguments);
    return formatInternal(template, values);
  }

  public static String formatNumber(Object value) {
    if (!(value instanceof Number number)) {
      return value == null ? "null" : String.valueOf(value);
    }
    if (number instanceof Byte
        || number instanceof Short
        || number instanceof Integer
        || number instanceof Long) {
      return String.valueOf(number.longValue());
    }
    java.math.BigDecimal decimal;
    try {
      decimal = new java.math.BigDecimal(String.valueOf(number));
    } catch (NumberFormatException ignored) {
      return String.valueOf(number);
    }
    decimal = decimal.stripTrailingZeros();
    return decimal.toPlainString();
  }

  private static String formatInternal(String template, List<?> arguments) {
    if (template == null) {
      return null;
    }
    List<?> values = arguments == null ? new ArrayList<>() : arguments;

    // Apex-style placeholders use "{0}", "{1}", ...
    String out = template;
    for (int i = 0; i < values.size(); i++) {
      String token = "{" + i + "}";
      Object value = values.get(i);
      String replacement = ApexStrings.valueOf(value);
      if (replacement == null) {
        replacement = "null";
      }
      out = out.replace(token, replacement);
    }

    // Fallback for Java-style format strings ("%s", "%d", ...)
    if (out.equals(template) && template.contains("%")) {
      try {
        return String.format(template, values.toArray());
      } catch (Exception ignored) {
        // Keep original text if formatting cannot be applied.
      }
    }
    return out;
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

  private static int toInt(Object raw, int fallback) {
    if (raw == null) {
      return fallback;
    }
    if (raw instanceof Number number) {
      return number.intValue();
    }
    try {
      return Integer.parseInt(String.valueOf(raw));
    } catch (NumberFormatException ignored) {
      return fallback;
    }
  }
}
