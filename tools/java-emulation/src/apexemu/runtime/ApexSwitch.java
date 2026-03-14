package apexemu.runtime;

import java.lang.reflect.Field;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.util.Map;

public final class ApexSwitch {
  private static final Object UNRESOLVED = new Object();

  private ApexSwitch() {}

  public static String typeName(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof ApexSObject row) {
      String type = row.type();
      if (type != null && !type.isBlank()) {
        return type;
      }
    }
    return String.valueOf(value);
  }

  public static Schema.SObjectType getSObjectType(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof Schema.SObjectType type) {
      return type;
    }
    if (value instanceof Schema.DescribeSObjectResult describe) {
      return describe.getSObjectType();
    }
    if (value instanceof ApexSObject row) {
      return row.getSObjectType();
    }
    Schema.SObjectType reflectedType = reflectSObjectType(value);
    if (reflectedType != null) {
      return reflectedType;
    }
    if (value instanceof java.util.List<?> list) {
      if (list.isEmpty()) {
        return null;
      }
      return getSObjectType(list.get(0));
    }
    // If value is a String that looks like an ID, resolve it from the store
    if (value instanceof String id && id.length() >= 15) {
      String resolvedType = ApexStore.resolveTypeFromId(id);
      if (resolvedType != null) {
        return new Schema.SObjectType(resolvedType);
      }
      String resolvedByPrefix = resolveTypeFromKeyPrefix(id);
      if (resolvedByPrefix != null) {
        return new Schema.SObjectType(resolvedByPrefix);
      }
    }
    if (value instanceof String text && !text.isBlank()) {
      return new Schema.SObjectType(text.trim());
    }
    return null;
  }

  private static Schema.SObjectType reflectSObjectType(Object value) {
    if (value == null) {
      return null;
    }
    Object reflected = invokeNoArg(value, "getSObjectType");
    if (reflected == null) {
      reflected = invokeNoArg(value, "getSobjectType");
    }
    if (reflected == null) {
      reflected = invokeNoArg(value, "getType");
    }
    if (reflected instanceof Schema.SObjectType type) {
      return type;
    }
    if (reflected instanceof System.Type systemType) {
      String typeName = systemType.getName();
      if (typeName == null || typeName.isBlank()) {
        return null;
      }
      return new Schema.SObjectType(extractSimpleTypeName(typeName));
    }
    if (reflected instanceof Class<?> klass) {
      return new Schema.SObjectType(extractSimpleTypeName(klass.getName()));
    }
    if (reflected instanceof String text && !text.isBlank()) {
      return new Schema.SObjectType(text.trim());
    }
    return null;
  }

  private static Object invokeNoArg(Object value, String methodName) {
    if (value == null || methodName == null || methodName.isBlank()) {
      return null;
    }
    Class<?> current = value.getClass();
    while (current != null) {
      for (java.lang.reflect.Method method : current.getDeclaredMethods()) {
        if (!method.getName().equalsIgnoreCase(methodName) || method.getParameterCount() != 0) {
          continue;
        }
        method.setAccessible(true);
        try {
          return method.invoke(value);
        } catch (ReflectiveOperationException ignored) {
          return null;
        }
      }
      current = current.getSuperclass();
    }
    return null;
  }

  private static String extractSimpleTypeName(String rawTypeName) {
    if (rawTypeName == null || rawTypeName.isBlank()) {
      return "";
    }
    String normalized = rawTypeName.trim().replace('$', '.');
    int dot = normalized.lastIndexOf('.');
    if (dot >= 0 && dot + 1 < normalized.length()) {
      return normalized.substring(dot + 1);
    }
    return normalized;
  }

  private static String resolveTypeFromKeyPrefix(String id) {
    if (id == null) {
      return null;
    }
    String trimmed = id.trim();
    if (trimmed.length() < 3) {
      return null;
    }
    String prefix = trimmed.substring(0, 3);
    for (Schema.SObjectType token : Schema.getGlobalDescribe().values()) {
      if (token == null) {
        continue;
      }
      Schema.DescribeSObjectResult describe = token.getDescribe();
      if (describe == null) {
        continue;
      }
      String keyPrefix = describe.getKeyPrefix();
      if (keyPrefix != null && keyPrefix.equalsIgnoreCase(prefix)) {
        return describe.getName();
      }
    }
    String resolvedBySchema = Schema.resolveTypeNameByKeyPrefix(prefix);
    if (resolvedBySchema != null && !resolvedBySchema.isBlank()) {
      return resolvedBySchema;
    }
    return null;
  }

  @SuppressWarnings("unchecked")
  public static <T> T getAs(Object value, String field) {
    if (value == null || field == null || field.isBlank()) {
      return null;
    }
    if (value instanceof ApexSObject row) {
      return row.getAs(field);
    }
    if (value instanceof Map<?, ?> map) {
      Object direct = map.get(field);
      if (direct != null) {
        return (T) direct;
      }
      for (Map.Entry<?, ?> entry : map.entrySet()) {
        Object key = entry.getKey();
        if (key != null && key.toString().equalsIgnoreCase(field)) {
          return (T) entry.getValue();
        }
      }
      return null;
    }

    Class<?> current = value.getClass();
    while (current != null) {
      for (Field declaredField : current.getDeclaredFields()) {
        if (!declaredField.getName().equalsIgnoreCase(field)) {
          continue;
        }
        declaredField.setAccessible(true);
        try {
          return (T) declaredField.get(value);
        } catch (IllegalAccessException ignored) {
          return null;
        }
      }
      current = current.getSuperclass();
    }
    Object virtual = resolveKnownVirtualField(value, field);
    if (virtual != UNRESOLVED) {
      return (T) virtual;
    }
    return null;
  }

  @SuppressWarnings({"unchecked", "rawtypes"})
  public static void set(Object value, String field, Object nextValue) {
    if (value == null || field == null || field.isBlank()) {
      return;
    }
    if (value instanceof ApexSObject row) {
      row.set(field, nextValue);
      return;
    }
    if (value instanceof Map<?, ?> map) {
      ((Map) map).put(field, nextValue);
      return;
    }

    Class<?> current = value.getClass();
    while (current != null) {
      for (Field declaredField : current.getDeclaredFields()) {
        if (!declaredField.getName().equalsIgnoreCase(field)) {
          continue;
        }
        declaredField.setAccessible(true);
        try {
          declaredField.set(value, coerceFieldValue(declaredField.getType(), nextValue));
        } catch (IllegalAccessException ignored) {
          // no-op
        }
        return;
      }
      current = current.getSuperclass();
    }
  }

  private static Object coerceFieldValue(Class<?> fieldType, Object value) {
    if (fieldType == null || value == null) {
      return value;
    }
    Class<?> boxedType = box(fieldType);
    if (boxedType.isInstance(value)) {
      return value;
    }
    if (Number.class.isAssignableFrom(boxedType) && value instanceof Number number) {
      if (boxedType == Byte.class) {
        return number.byteValue();
      }
      if (boxedType == Short.class) {
        return number.shortValue();
      }
      if (boxedType == Integer.class) {
        return number.intValue();
      }
      if (boxedType == Long.class) {
        return number.longValue();
      }
      if (boxedType == Float.class) {
        return number.floatValue();
      }
      if (boxedType == Double.class) {
        return number.doubleValue();
      }
    }
    if (boxedType == Boolean.class && value instanceof String text) {
      if ("true".equalsIgnoreCase(text)) {
        return Boolean.TRUE;
      }
      if ("false".equalsIgnoreCase(text)) {
        return Boolean.FALSE;
      }
    }
    if (boxedType == String.class) {
      return String.valueOf(value);
    }
    return value;
  }

  private static Class<?> box(Class<?> type) {
    if (type == null || !type.isPrimitive()) {
      return type;
    }
    if (type == boolean.class) {
      return Boolean.class;
    }
    if (type == byte.class) {
      return Byte.class;
    }
    if (type == short.class) {
      return Short.class;
    }
    if (type == int.class) {
      return Integer.class;
    }
    if (type == long.class) {
      return Long.class;
    }
    if (type == float.class) {
      return Float.class;
    }
    if (type == double.class) {
      return Double.class;
    }
    if (type == char.class) {
      return Character.class;
    }
    return type;
  }

  public static String getStackTraceString(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof Throwable error) {
      StringWriter writer = new StringWriter();
      PrintWriter printWriter = new PrintWriter(writer);
      error.printStackTrace(printWriter);
      printWriter.flush();
      return writer.toString();
    }
    return String.valueOf(value);
  }

  public static String getTypeName(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof System.Exception apexError) {
      String typeName = apexError.getTypeName();
      if (typeName == null || typeName.isBlank()) {
        return "System.Exception";
      }
      String normalized = typeName.replace('$', '.');
      int runtimePrefix = normalized.indexOf("apexemu.runtime.");
      if (runtimePrefix == 0) {
        String simple = normalized.substring("apexemu.runtime.".length());
        if (simple.startsWith("System.")) {
          return simple;
        }
        int dot = simple.lastIndexOf('.');
        if (dot >= 0 && dot + 1 < simple.length()) {
          simple = simple.substring(dot + 1);
        }
        return "System." + simple;
      }
      return normalized;
    }
    return value.getClass().getName();
  }

  public static String formatGMT(Object value, String pattern) {
    if (value == null) {
      return null;
    }
    if (value instanceof DateTime dateTime) {
      return dateTime.formatGMT(pattern);
    }
    return String.valueOf(value);
  }

  private static Object resolveKnownVirtualField(Object value, String field) {
    if (value == null || field == null || field.isBlank()) {
      return UNRESOLVED;
    }
    String simpleName = value.getClass().getSimpleName();
    if (!"OrgShape".equals(simpleName)) {
      return UNRESOLVED;
    }

    ApexSObject org = null;
    Object orgRaw = reflectFieldValue(value, "orgShape");
    if (orgRaw instanceof ApexSObject row) {
      org = row;
    }

    String normalized = field.trim().toLowerCase();
    return switch (normalized) {
      case "multicurrencyenabled" -> UserInfo.isMultiCurrencyOrganization();
      case "lightningenabled" -> {
        String uiTheme = UserInfo.getUiThemeDisplayed();
        yield uiTheme != null && uiTheme.toLowerCase().contains("theme4");
      }
      case "issandbox" -> org == null ? null : org.getAs("IsSandbox");
      case "orgtype" -> org == null ? null : org.getAs("OrganizationType");
      case "isreadonly" -> org == null ? null : org.getAs("IsReadOnly");
      case "instancename", "podname" -> org == null ? null : org.getAs("InstanceName");
      case "getfiscalyearstartmonth" -> org == null ? null : org.getAs("FiscalYearStartMonth");
      case "id" -> org == null ? null : org.getAs("Id");
      case "locale" -> org == null ? null : org.getAs("LanguageLocaleKey");
      case "timezonekey" -> org == null ? null : org.getAs("TimeZoneSidKey");
      case "name" -> org == null ? null : org.getAs("Name");
      case "namespaceprefix" -> org == null ? null : org.getAs("NamespacePrefix");
      case "hasnamespaceprefix" -> ApexStrings.isNotBlank(org == null ? null : org.getAs("NamespacePrefix"));
      default -> UNRESOLVED;
    };
  }

  private static Object reflectFieldValue(Object value, String field) {
    if (value == null || field == null || field.isBlank()) {
      return null;
    }
    Class<?> current = value.getClass();
    while (current != null) {
      for (Field declaredField : current.getDeclaredFields()) {
        if (!declaredField.getName().equalsIgnoreCase(field)) {
          continue;
        }
        declaredField.setAccessible(true);
        try {
          return declaredField.get(value);
        } catch (IllegalAccessException ignored) {
          return null;
        }
      }
      current = current.getSuperclass();
    }
    return null;
  }
}
