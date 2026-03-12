package apexemu.runtime;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class JSON {
  private static final DateTimeFormatter ISO_MILLIS_UTC =
      DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC);

  private JSON() {}

  public static String serialize(Object value) {
    if (value == null) {
      return "null";
    }
    if (value instanceof String s) {
      return "\"" + escape(s) + "\"";
    }
    if (value instanceof DateTime datetime) {
      return "\"" + escape(formatDateTime(datetime)) + "\"";
    }
    if (value instanceof Date date) {
      return "\"" + escape(String.valueOf(date)) + "\"";
    }
    if (value instanceof Number || value instanceof Boolean) {
      return String.valueOf(value);
    }
    if (value instanceof ApexSObject row) {
      StringBuilder out = new StringBuilder();
      out.append("{\"attributes\":{\"type\":\"").append(escape(row.type())).append("\"}");
      if (row.id() != null) {
        out.append(",\"Id\":\"").append(escape(row.id())).append("\"");
      }
      for (Map.Entry<String, Object> entry : row.fields().entrySet()) {
        out.append(",\"").append(escape(entry.getKey())).append("\":");
        out.append(serialize(entry.getValue()));
      }
      out.append("}");
      return out.toString();
    }
    if (value instanceof Map<?, ?> map) {
      return serializeMap(map);
    }
    if (value instanceof Iterable<?> iterable) {
      return serializeIterable(iterable);
    }
    if (value.getClass().isArray()) {
      return serializeArray(value);
    }
    if (!value.getClass().getName().startsWith("java.")) {
      return serializeReflective(value);
    }
    return "\"" + escape(String.valueOf(value)) + "\"";
  }

  public static String serialize(Object value, Boolean suppressApexObjectNulls) {
    return serialize(value);
  }

  public static String serializePretty(Object value) {
    return serialize(value);
  }

  public static <T> T deserialize(String payload, Class<T> clazz) {
    try {
      if (clazz == null) {
        return null;
      }
      if (clazz == String.class) {
        return clazz.cast(payload);
      }
      if (clazz == List.class) {
        return clazz.cast(deserializeList(payload, ApexSObject.class));
      }

      Object parsed = parseJson(payload);
      if (parsed == null) {
        return null;
      }
      if (clazz.isInstance(parsed)) {
        return clazz.cast(parsed);
      }
      if (parsed instanceof Map<?, ?> map) {
        Map<String, Object> objectMap = castMap(map);
        Object mapped;
        if (ApexSObject.class.isAssignableFrom(clazz)) {
          mapped = mapToTypedApexSObject(objectMap, clazz);
        } else {
          mapped = mapToObject(objectMap, clazz);
        }
        return clazz.cast(mapped);
      }
      throw new UnsupportedOperationException(
          "deserialize cannot coerce JSON payload into " + clazz.getSimpleName());
    } catch (RuntimeException error) {
      throw asJsonException(error);
    }
  }

  @SuppressWarnings("unchecked")
  public static <T> T deserialize(String payload, System.Type type) {
    if (type == null) {
      return null;
    }
    String typeName = type.getName();
    if (typeName == null || typeName.isBlank()) {
      return (T) deserializeUntyped(payload);
    }
    String normalizedType = typeName.trim();
    if (isListTypeName(normalizedType)) {
      Class<?> listElementClass = resolveListElementClass(normalizedType);
      return (T) deserializeList(payload, (Class<Object>) listElementClass);
    }

    if (containsSObjectType(normalizedType)) {
      try {
        return (T) deserializeSObjectPayload(payload, normalizedType);
      } catch (RuntimeException error) {
        throw asJsonException(error);
      }
    }

    ClassLoader cl = Thread.currentThread().getContextClassLoader();
    if (cl == null) {
      cl = JSON.class.getClassLoader();
    }
    String[] candidates =
        new String[] {normalizedType, "generated." + normalizedType, "apexemu.runtime." + normalizedType};
    for (String candidate : candidates) {
      try {
        Class<?> klass = Class.forName(candidate, true, cl);
        return (T) deserialize(payload, (Class<Object>) klass);
      } catch (ClassNotFoundException ignored) {
        // try next candidate
      }
    }
    Class<?> resolvedType = resolveTypeClass(type);
    if (resolvedType != null) {
      return (T) deserialize(payload, (Class<Object>) resolvedType);
    }
    try {
      return (T) deserializeSObjectPayload(payload, normalizedType);
    } catch (RuntimeException error) {
      throw asJsonException(error);
    }
  }

  public static <T> List<T> deserializeList(String payload, Class<T> elementClass) {
    if (payload == null || payload.isBlank()) {
      throw new JSONException("Argument cannot be null.");
    }
    try {
      Object parsed = parseJson(payload);
      if (!(parsed instanceof List<?> rawList)) {
        throw new JSONException("JSON payload is not a list");
      }

      List<T> out = new ArrayList<>(rawList.size());
      for (Object raw : rawList) {
        out.add(convertListElement(raw, elementClass));
      }
      return out;
    } catch (RuntimeException error) {
      throw asJsonException(error);
    }
  }

  @SuppressWarnings("unchecked")
  public static List<?> deserializeList(String payload, System.Type elementType) {
    Class<?> elementClass = resolveTypeClass(elementType);
    if (elementClass != null) {
      return deserializeList(payload, (Class<Object>) elementClass);
    }
    if (elementType != null && elementType.getName() != null) {
      String typeName = elementType.getName().trim();
      if (typeName.equalsIgnoreCase("ApexSObject") || containsSObjectType(typeName)) {
        return deserializeList(payload, ApexSObject.class);
      }
    }
    return deserializeList(payload, Object.class);
  }

  public static Object deserializeUntyped(String payload) {
    try {
      return parseJson(payload);
    } catch (RuntimeException error) {
      throw asJsonException(error);
    }
  }

  public static <T> T deserializeStrict(String payload, Class<T> clazz) {
    return deserialize(payload, clazz);
  }

  public static <T> T deserializeStrict(String payload, System.Type type) {
    return deserialize(payload, type);
  }

  public static JSONParser createParser(String payload) {
    return new JSONParser(payload);
  }

  public static JSONGenerator createGenerator(boolean pretty) {
    return new JSONGenerator(pretty);
  }

  private static String serializeMap(Map<?, ?> map) {
    StringBuilder out = new StringBuilder();
    out.append("{");
    boolean first = true;
    for (Map.Entry<?, ?> entry : map.entrySet()) {
      if (!first) {
        out.append(",");
      }
      first = false;
      String key = entry.getKey() == null ? "null" : String.valueOf(entry.getKey());
      out.append("\"").append(escape(key)).append("\":").append(serialize(entry.getValue()));
    }
    out.append("}");
    return out.toString();
  }

  private static String serializeIterable(Iterable<?> iterable) {
    StringBuilder out = new StringBuilder();
    out.append("[");
    boolean first = true;
    for (Object item : iterable) {
      if (!first) {
        out.append(",");
      }
      first = false;
      out.append(serialize(item));
    }
    out.append("]");
    return out.toString();
  }

  private static String serializeArray(Object array) {
    int length = java.lang.reflect.Array.getLength(array);
    StringBuilder out = new StringBuilder();
    out.append("[");
    for (int i = 0; i < length; i++) {
      if (i > 0) {
        out.append(",");
      }
      out.append(serialize(java.lang.reflect.Array.get(array, i)));
    }
    out.append("]");
    return out.toString();
  }

  private static String serializeReflective(Object value) {
    StringBuilder out = new StringBuilder();
    out.append("{");
    boolean first = true;
    Class<?> cursor = value.getClass();
    while (cursor != null && cursor != Object.class) {
      for (Field field : cursor.getDeclaredFields()) {
        if (Modifier.isStatic(field.getModifiers()) || Modifier.isTransient(field.getModifiers())) {
          continue;
        }
        try {
          field.setAccessible(true);
          Object fieldValue = field.get(value);
          if (!first) {
            out.append(",");
          }
          first = false;
          out.append("\"").append(escape(field.getName())).append("\":").append(serialize(fieldValue));
        } catch (IllegalAccessException ignored) {
          // skip inaccessible fields
        }
      }
      cursor = cursor.getSuperclass();
    }
    out.append("}");
    return out.toString();
  }

  private static String escape(String value) {
    if (value == null || value.isEmpty()) {
      return "";
    }
    return value
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t");
  }

  @SuppressWarnings("unchecked")
  private static Map<String, Object> castMap(Map<?, ?> map) {
    return (Map<String, Object>) map;
  }

  @SuppressWarnings("unchecked")
  private static <T> T convertListElement(Object raw, Class<T> elementClass) {
    if (elementClass == null || elementClass == Object.class) {
      return (T) raw;
    }
    if (raw == null) {
      return null;
    }
    if (elementClass.isInstance(raw)) {
      return elementClass.cast(raw);
    }

    if (raw instanceof Map<?, ?> map) {
      Map<String, Object> objectMap = castMap(map);
      if (elementClass == ApexSObject.class) {
        return elementClass.cast(mapToApexSObject(objectMap));
      }
      return elementClass.cast(mapToObject(objectMap, elementClass));
    }

    Object convertedScalar = convertScalar(raw, elementClass);
    if (convertedScalar != null) {
      return elementClass.cast(convertedScalar);
    }
    throw new IllegalArgumentException(
        "cannot coerce list element into " + elementClass.getSimpleName());
  }

  private static boolean containsSObjectType(String typeName) {
    if (typeName == null || typeName.isBlank()) {
      return false;
    }
    for (String knownType : Schema.getGlobalDescribe().keySet()) {
      if (knownType != null && knownType.equalsIgnoreCase(typeName)) {
        return true;
      }
    }
    return false;
  }

  private static boolean isListTypeName(String typeName) {
    if (typeName == null || typeName.isBlank()) {
      return false;
    }
    String normalized = typeName.trim();
    return normalized.equalsIgnoreCase("List")
        || normalized.regionMatches(true, 0, "List<", 0, "List<".length());
  }

  private static boolean isMapTypeName(String typeName) {
    if (typeName == null || typeName.isBlank()) {
      return false;
    }
    String normalized = typeName.trim();
    return normalized.equalsIgnoreCase("Map")
        || normalized.regionMatches(true, 0, "Map<", 0, "Map<".length());
  }

  private static Class<?> resolveListElementClass(String listTypeName) {
    if (listTypeName == null || listTypeName.isBlank()) {
      return Object.class;
    }
    String elementTypeName = extractFirstGenericTypeArgument(listTypeName.trim());
    if (elementTypeName == null || elementTypeName.isBlank()) {
      return Object.class;
    }
    if (elementTypeName.equalsIgnoreCase("Object") || isMapTypeName(elementTypeName)) {
      return Object.class;
    }
    if (elementTypeName.equalsIgnoreCase("ApexSObject")
        || elementTypeName.equalsIgnoreCase("SObject")
        || containsSObjectType(elementTypeName)) {
      return ApexSObject.class;
    }
    try {
      System.Type elementType = System.Type.forName(elementTypeName);
      Class<?> resolved = resolveTypeClass(elementType);
      if (resolved != null) {
        return resolved;
      }
    } catch (RuntimeException ignored) {
      // fall through to generic object
    }
    return Object.class;
  }

  private static String extractFirstGenericTypeArgument(String collectionTypeName) {
    if (collectionTypeName == null || collectionTypeName.isBlank()) {
      return null;
    }
    int open = collectionTypeName.indexOf('<');
    if (open < 0) {
      return null;
    }
    int close = collectionTypeName.lastIndexOf('>');
    if (close <= open) {
      return null;
    }
    int depth = 0;
    int end = close;
    for (int i = open + 1; i < close; i += 1) {
      char ch = collectionTypeName.charAt(i);
      if (ch == '<') {
        depth += 1;
        continue;
      }
      if (ch == '>') {
        if (depth > 0) {
          depth -= 1;
        }
        continue;
      }
      if (ch == ',' && depth == 0) {
        end = i;
        break;
      }
    }
    String argument = collectionTypeName.substring(open + 1, end).trim();
    return argument.isEmpty() ? null : argument;
  }

  private static Object deserializeSObjectPayload(String payload, String typeName) {
    Object parsed = parseJson(payload);
    if (parsed == null) {
      return null;
    }
    if (parsed instanceof Map<?, ?> map) {
      return mapToApexSObjectWithType(castMap(map), typeName);
    }
    if (parsed instanceof List<?> list) {
      List<ApexSObject> out = new ArrayList<>(list.size());
      for (Object entry : list) {
        if (entry instanceof Map<?, ?> rowMap) {
          out.add(mapToApexSObjectWithType(castMap(rowMap), typeName));
        } else if (entry instanceof ApexSObject row) {
          out.add(row);
        }
      }
      return out;
    }
    return parsed;
  }

  private static ApexSObject mapToApexSObject(Map<String, Object> values) {
    return mapToApexSObjectWithType(values, null);
  }

  private static Class<?> resolveTypeClass(System.Type type) {
    if (type == null || type.getName() == null || type.getName().isBlank()) {
      return null;
    }
    String normalized = type.getName().trim();
    String[] candidates = {
      normalized,
      normalized.replace('.', '$'),
      "generated." + normalized,
      "generated." + normalized.replace('.', '$'),
      "apexemu.runtime." + normalized,
      "apexemu.runtime." + normalized.replace('.', '$')
    };
    ClassLoader cl = Thread.currentThread().getContextClassLoader();
    if (cl == null) {
      cl = JSON.class.getClassLoader();
    }
    for (String candidate : candidates) {
      try {
        return Class.forName(candidate, true, cl);
      } catch (ClassNotFoundException ignored) {
        // try next candidate
      }
    }
    try {
      Object instance = type.newInstance();
      if (instance != null) {
        return instance.getClass();
      }
    } catch (RuntimeException ignored) {
      // type token may not be instantiable
    }
    return null;
  }

  private static ApexSObject mapToApexSObjectWithType(Map<String, Object> values, String forcedType) {
    String type =
        (forcedType == null || forcedType.isBlank()) ? inferSObjectType(values) : forcedType.trim();
    ApexSObject row = ApexSObject.of(type);
    for (Map.Entry<String, Object> entry : values.entrySet()) {
      String key = entry.getKey();
      if (key == null || key.isBlank()) {
        continue;
      }
      if ("attributes".equalsIgnoreCase(key)) {
        continue;
      }
      row.set(key, normalizeJsonValue(entry.getValue()));
    }
    return row;
  }

  private static Object mapToTypedApexSObject(Map<String, Object> values, Class<?> clazz) {
    ApexSObject mapped = mapToApexSObject(values);
    if (clazz == ApexSObject.class) {
      return mapped;
    }
    try {
      Constructor<?> constructor = clazz.getDeclaredConstructor();
      constructor.setAccessible(true);
      Object instance = constructor.newInstance();
      if (instance instanceof ApexSObject typed) {
        if (mapped.id() != null) {
          typed.withId(mapped.id());
        }
        for (Map.Entry<String, Object> entry : mapped.fields().entrySet()) {
          typed.set(entry.getKey(), normalizeJsonValue(entry.getValue()));
        }
        return typed;
      }
      return mapped;
    } catch (ReflectiveOperationException ignored) {
      return mapped;
    }
  }

  private static String inferSObjectType(Map<String, Object> values) {
    if (values == null || values.isEmpty()) {
      return "Generic__c";
    }
    Object attributes = values.get("attributes");
    if (attributes instanceof Map<?, ?> attrMap) {
      Object type = castMap(attrMap).get("type");
      if (type != null) {
        String text = String.valueOf(type).trim();
        if (!text.isEmpty()) {
          return text;
        }
      }
    }
    if (values.containsKey("Broker_Id__c")) {
      return "Broker__c";
    }
    if (values.containsKey("Address__c") || values.containsKey("Price__c") || values.containsKey("Beds__c")) {
      return "Property__c";
    }
    if (values.containsKey("FirstName") && values.containsKey("LastName")) {
      return "Contact";
    }
    return "Generic__c";
  }

  private static String formatDateTime(DateTime value) {
    if (value == null) {
      return "";
    }
    return ISO_MILLIS_UTC.format(Instant.ofEpochMilli(value.getTime()));
  }

  private static Object mapToObject(Map<String, Object> values, Class<?> clazz) {
    try {
      Constructor<?> constructor = clazz.getDeclaredConstructor();
      constructor.setAccessible(true);
      Object instance = constructor.newInstance();

      for (Map.Entry<String, Object> entry : values.entrySet()) {
        String fieldName = entry.getKey();
        if (fieldName == null || fieldName.isBlank()) {
          continue;
        }
        Field field = findField(clazz, fieldName);
        if (field == null) {
          continue;
        }
        field.setAccessible(true);
        Object converted = convertForField(entry.getValue(), field.getType());
        field.set(instance, converted);
      }
      return instance;
    } catch (ReflectiveOperationException error) {
      throw new IllegalArgumentException(
          "unable to materialize " + clazz.getSimpleName() + " from JSON object",
          error);
    }
  }

  private static Field findField(Class<?> clazz, String fieldName) {
    Class<?> cursor = clazz;
    while (cursor != null && cursor != Object.class) {
      for (Field field : cursor.getDeclaredFields()) {
        if (field.getName().equals(fieldName)) {
          return field;
        }
      }
      cursor = cursor.getSuperclass();
    }
    return null;
  }

  private static Object convertForField(Object raw, Class<?> targetType) {
    if (raw == null) {
      return null;
    }
    if (targetType == null || targetType == Object.class || targetType.isInstance(raw)) {
      return raw;
    }
    Object scalar = convertScalar(raw, targetType);
    if (scalar != null) {
      return scalar;
    }
    if (raw instanceof Map<?, ?> map && targetType == ApexSObject.class) {
      return mapToApexSObject(castMap(map));
    }
    if (raw instanceof Map<?, ?> map && targetType != Map.class) {
      return mapToObject(castMap(map), targetType);
    }
    return raw;
  }

  private static Object convertScalar(Object raw, Class<?> targetType) {
    if (raw == null || targetType == null) {
      return null;
    }
    if (targetType == String.class) {
      return String.valueOf(raw);
    }
    if (raw instanceof Number number) {
      if (targetType == Integer.class || targetType == int.class) {
        return number.intValue();
      }
      if (targetType == Long.class || targetType == long.class) {
        return number.longValue();
      }
      if (targetType == Double.class || targetType == double.class) {
        return number.doubleValue();
      }
      if (targetType == Float.class || targetType == float.class) {
        return number.floatValue();
      }
    }
    if (targetType == Boolean.class || targetType == boolean.class) {
      if (raw instanceof Boolean bool) {
        return bool;
      }
      if (raw instanceof String text) {
        return Boolean.parseBoolean(text);
      }
    }
    if ((targetType == Double.class || targetType == double.class) && raw instanceof String text) {
      try {
        return Double.parseDouble(text.trim());
      } catch (NumberFormatException ignored) {
        return null;
      }
    }
    if ((targetType == Integer.class || targetType == int.class) && raw instanceof String text) {
      try {
        return Integer.parseInt(text.trim());
      } catch (NumberFormatException ignored) {
        return null;
      }
    }
    return null;
  }

  private static Object normalizeJsonValue(Object raw) {
    if (raw instanceof Map<?, ?> map) {
      Map<String, Object> objectMap = castMap(map);
      if (looksLikeRelationshipEnvelope(objectMap)) {
        Object recordsRaw = objectMap.get("records");
        if (recordsRaw instanceof List<?> records) {
          List<Object> out = new ArrayList<>(records.size());
          for (Object record : records) {
            out.add(normalizeJsonValue(record));
          }
          return out;
        }
      }

      Object attributes = objectMap.get("attributes");
      if (attributes instanceof Map<?, ?>) {
        return mapToApexSObject(objectMap);
      }

      Map<String, Object> out = new LinkedHashMap<>();
      for (Map.Entry<String, Object> entry : objectMap.entrySet()) {
        out.put(entry.getKey(), normalizeJsonValue(entry.getValue()));
      }
      return out;
    }
    if (raw instanceof List<?> list) {
      List<Object> out = new ArrayList<>(list.size());
      for (Object value : list) {
        out.add(normalizeJsonValue(value));
      }
      return out;
    }
    return raw;
  }

  private static boolean looksLikeRelationshipEnvelope(Map<String, Object> values) {
    if (values == null || values.isEmpty()) {
      return false;
    }
    return values.containsKey("records")
        && (values.containsKey("totalSize") || values.containsKey("done"));
  }

  private static Object parseJson(String payload) {
    if (payload == null) {
      return null;
    }
    String trimmed = payload.trim();
    if (trimmed.isEmpty()) {
      return null;
    }
    RuntimeException firstError = null;
    try {
      return parseJsonStrict(trimmed);
    } catch (RuntimeException error) {
      firstError = error;
    }

    String normalized = normalizeEscapedPayload(trimmed);
    if (!normalized.equals(trimmed)) {
      try {
        return parseJsonStrict(normalized);
      } catch (RuntimeException ignored) {
        // try final fallback
      }
    }

    if (trimmed.length() >= 2 && trimmed.startsWith("\"") && trimmed.endsWith("\"")) {
      try {
        Object parsed = parseJsonStrict(trimmed);
        if (parsed instanceof String inner) {
          String innerTrimmed = inner.trim();
          if (innerTrimmed.startsWith("{") || innerTrimmed.startsWith("[")) {
            return parseJsonStrict(innerTrimmed);
          }
        }
      } catch (RuntimeException ignored) {
        // fall through to original parse error
      }
    }

    throw firstError;
  }

  private static Object parseJsonStrict(String payload) {
    JsonParser parser = new JsonParser(payload);
    Object value = parser.parseValue();
    parser.skipWhitespace();
    if (!parser.isAtEnd()) {
      throw new IllegalArgumentException("invalid JSON: trailing characters");
    }
    return value;
  }

  private static String normalizeEscapedPayload(String payload) {
    if (payload == null || payload.isEmpty()) {
      return payload == null ? "" : payload;
    }
    return payload
        .replace("\\n", "\n")
        .replace("\\r", "\r")
        .replace("\\t", "\t")
        .replace("\\\"", "\"");
  }

  private static JSONException asJsonException(RuntimeException error) {
    if (error instanceof JSONException jsonException) {
      // Ensure "Malformed JSON" prefix for parse errors that lack it
      String msg = jsonException.getMessage();
      if (msg != null && !msg.startsWith("Malformed JSON") && !msg.startsWith("Argument")) {
        return new JSONException("Malformed JSON: " + msg, jsonException);
      }
      return jsonException;
    }
    String message = error.getMessage();
    if (message == null || message.isBlank()) {
      message = "JSON parse error";
    }
    return new JSONException("Malformed JSON: " + message, error);
  }

  private static final class JsonParser {
    private final String text;
    private int index;

    JsonParser(String text) {
      this.text = text == null ? "" : text;
      this.index = 0;
    }

    Object parseValue() {
      skipWhitespace();
      if (isAtEnd()) {
        return null;
      }
      char ch = text.charAt(index);
      if (ch == '{') {
        return parseObject();
      }
      if (ch == '[') {
        return parseArray();
      }
      if (ch == '"') {
        return parseString();
      }
      if (ch == 't' || ch == 'f') {
        return parseBoolean();
      }
      if (ch == 'n') {
        return parseNull();
      }
      return parseNumber();
    }

    private Map<String, Object> parseObject() {
      expect('{');
      skipWhitespace();
      Map<String, Object> out = new LinkedHashMap<>();
      if (peek('}')) {
        expect('}');
        return out;
      }
      while (true) {
        skipWhitespace();
        String key = parseString();
        skipWhitespace();
        expect(':');
        Object value = parseValue();
        out.put(key, value);
        skipWhitespace();
        if (peek('}')) {
          expect('}');
          break;
        }
        expect(',');
      }
      return out;
    }

    private List<Object> parseArray() {
      expect('[');
      skipWhitespace();
      List<Object> out = new ArrayList<>();
      if (peek(']')) {
        expect(']');
        return out;
      }
      while (true) {
        out.add(parseValue());
        skipWhitespace();
        if (peek(']')) {
          expect(']');
          break;
        }
        expect(',');
      }
      return out;
    }

    private String parseString() {
      expect('"');
      StringBuilder out = new StringBuilder();
      while (!isAtEnd()) {
        char ch = text.charAt(index++);
        if (ch == '"') {
          return out.toString();
        }
        if (ch != '\\') {
          out.append(ch);
          continue;
        }
        if (isAtEnd()) {
          throw new IllegalArgumentException("invalid JSON escape");
        }
        char esc = text.charAt(index++);
        switch (esc) {
          case '"' -> out.append('"');
          case '\\' -> out.append('\\');
          case '/' -> out.append('/');
          case 'b' -> out.append('\b');
          case 'f' -> out.append('\f');
          case 'n' -> out.append('\n');
          case 'r' -> out.append('\r');
          case 't' -> out.append('\t');
          case 'u' -> out.append(parseUnicodeEscape());
          default -> throw new IllegalArgumentException("invalid JSON escape: \\" + esc);
        }
      }
      throw new IllegalArgumentException("unterminated JSON string");
    }

    private char parseUnicodeEscape() {
      if (index + 4 > text.length()) {
        throw new IllegalArgumentException("invalid unicode escape");
      }
      String hex = text.substring(index, index + 4);
      index += 4;
      try {
        return (char) Integer.parseInt(hex, 16);
      } catch (NumberFormatException error) {
        throw new IllegalArgumentException("invalid unicode escape: " + hex, error);
      }
    }

    private Boolean parseBoolean() {
      if (text.regionMatches(index, "true", 0, 4)) {
        index += 4;
        return Boolean.TRUE;
      }
      if (text.regionMatches(index, "false", 0, 5)) {
        index += 5;
        return Boolean.FALSE;
      }
      throw new IllegalArgumentException("invalid boolean literal");
    }

    private Object parseNull() {
      if (!text.regionMatches(index, "null", 0, 4)) {
        throw new IllegalArgumentException("invalid null literal");
      }
      index += 4;
      return null;
    }

    private Number parseNumber() {
      int start = index;
      if (peek('-')) {
        index += 1;
      }
      while (!isAtEnd() && Character.isDigit(text.charAt(index))) {
        index += 1;
      }
      boolean hasFraction = false;
      if (!isAtEnd() && text.charAt(index) == '.') {
        hasFraction = true;
        index += 1;
        while (!isAtEnd() && Character.isDigit(text.charAt(index))) {
          index += 1;
        }
      }
      if (!isAtEnd()) {
        char exp = text.charAt(index);
        if (exp == 'e' || exp == 'E') {
          hasFraction = true;
          index += 1;
          if (!isAtEnd()) {
            char sign = text.charAt(index);
            if (sign == '+' || sign == '-') {
              index += 1;
            }
          }
          while (!isAtEnd() && Character.isDigit(text.charAt(index))) {
            index += 1;
          }
        }
      }
      String literal = text.substring(start, index);
      try {
        if (hasFraction) {
          return Double.parseDouble(literal);
        }
        long longVal = Long.parseLong(literal);
        if (longVal >= Integer.MIN_VALUE && longVal <= Integer.MAX_VALUE) {
          return Integer.valueOf((int) longVal);
        }
        return longVal;
      } catch (NumberFormatException error) {
        throw new IllegalArgumentException("invalid numeric literal: " + literal, error);
      }
    }

    void skipWhitespace() {
      while (!isAtEnd()) {
        char ch = text.charAt(index);
        if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') {
          index += 1;
          continue;
        }
        break;
      }
    }

    boolean isAtEnd() {
      return index >= text.length();
    }

    private void expect(char expected) {
      skipWhitespace();
      if (isAtEnd()) {
        throw new IllegalArgumentException("Unexpected end-of-input");
      }
      if (text.charAt(index) != expected) {
        throw new IllegalArgumentException("expected '" + expected + "' in JSON payload");
      }
      index += 1;
    }

    private boolean peek(char expected) {
      skipWhitespace();
      return !isAtEnd() && text.charAt(index) == expected;
    }
  }

  public static final class Parser {
    private final String payload;

    Parser(String payload) {
      this.payload = payload == null ? "" : payload;
    }

    public String getPayload() {
      return payload;
    }
  }

  public static final class Generator {
    private final StringBuilder out = new StringBuilder();

    public void writeString(String value) {
      out.append(serialize(value));
    }

    public String getAsString() {
      return out.toString();
    }
  }
}
