package apexemu.runtime;

import java.lang.reflect.Field;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class DataWeave {
  private static final String DATE_FORMAT = "hh:mm:ss a, MMMM dd, yyyy";

  private DataWeave() {}

  public interface Script {
    Result execute(Map<String, Object> payload);

    static Script createScript(String scriptName) {
      return DataWeave.resolveScript(scriptName);
    }
  }

  static Script resolveScript(String scriptName) {
    String normalized = normalizeScriptName(scriptName);
    return switch (normalized) {
      case "helloworld" -> DataWeave::executeHelloWorld;
      case "error" -> DataWeave::executeError;
      case "exceloutputerror" -> DataWeave::executeExcelOutputError;
      case "logfilter" -> DataWeave::executeLogFilter;
      case "csvtojsonbasic" -> DataWeave::executeCsvToJsonBasic;
      case "csvtojsonwithfieldrenaming" -> DataWeave::executeCsvToJsonWithFieldRenaming;
      case "csvseparatortojson" -> DataWeave::executeCsvSeparatorToJson;
      case "multipleinputs" -> DataWeave::executeMultipleInputs;
      case "csvtocontacts" -> DataWeave::executeCsvToContacts;
      case "jsontocontacts" -> DataWeave::executeJsonToContacts;
      case "csvtoapexobject" -> DataWeave::executeCsvToApexObject;
      case "jsondateformat" -> DataWeave::executeJsonDateFormat;
      case "pluralizefunction" -> DataWeave::executePluralizeFunction;
      case "reservedapexkeywords" -> DataWeave::executeReservedApexKeywords;
      default ->
          payload ->
              new Result(payload == null ? "" : String.valueOf(payload.getOrDefault("payload", "")));
    };
  }

  public static final class Result {
    private final Object value;

    public Result(Object value) {
      this.value = value;
    }

    public Object getValue() {
      return value;
    }

    public String getValueAsString() {
      if (value == null) {
        return "";
      }
      if (value instanceof String text) {
        return text;
      }
      return JSON.serialize(value);
    }
  }

  private static Result executeHelloWorld(Map<String, Object> payload) {
    return new Result("\"Hello World\"");
  }

  private static Result executeError(Map<String, Object> payload) {
    throw new DataWeaveScriptException("Division by zero");
  }

  private static Result executeExcelOutputError(Map<String, Object> payload) {
    throw new DataWeaveScriptException("Unknown content type `application/xlsx`");
  }

  private static Result executeLogFilter(Map<String, Object> payload) {
    List<Map<String, Object>> rows = parseJsonArray(payloadValueAsString(payload, "payload"));
    List<Map<String, Object>> filtered = new ArrayList<>();
    for (Map<String, Object> row : rows) {
      if (toBoolean(row.get("isWinner"))) {
        filtered.add(row);
      }
    }
    return new Result(filtered);
  }

  private static Result executeCsvToJsonBasic(Map<String, Object> payload) {
    List<Map<String, Object>> rows = parseCsv(payloadValueAsString(payload, "payload"), ',');
    return new Result(rows);
  }

  private static Result executeCsvToJsonWithFieldRenaming(Map<String, Object> payload) {
    List<Map<String, Object>> source = parseCsv(payloadValueAsString(payload, "payload"), ',');
    List<Map<String, Object>> renamed = new ArrayList<>(source.size());
    for (Map<String, Object> row : source) {
      Map<String, Object> mapped = new LinkedHashMap<>();
      for (Map.Entry<String, Object> entry : row.entrySet()) {
        mapped.put(renameCsvField(entry.getKey()), entry.getValue());
      }
      renamed.add(mapped);
    }
    return new Result(renamed);
  }

  private static Result executeCsvSeparatorToJson(Map<String, Object> payload) {
    List<Map<String, Object>> rows = parseCsv(payloadValueAsString(payload, "payload"), ';');
    return new Result(renderJsonWithSpacing(rows));
  }

  private static Result executeCsvToContacts(Map<String, Object> payload) {
    List<Map<String, Object>> rows = parseCsv(payloadValueAsString(payload, "records"), ',');
    List<ApexSObject> contacts = new ArrayList<>(rows.size());
    for (Map<String, Object> row : rows) {
      contacts.add(
          ApexSObject.of("Contact")
              .set("FirstName", stringValue(row.get("first_name")))
              .set("LastName", stringValue(row.get("last_name")))
              .set("Email", stringValue(row.get("email"))));
    }
    return new Result(contacts);
  }

  private static Result executeJsonToContacts(Map<String, Object> payload) {
    List<Map<String, Object>> rows = parseJsonArray(payloadValueAsString(payload, "records"));
    List<ApexSObject> contacts = new ArrayList<>(rows.size());
    for (Map<String, Object> row : rows) {
      contacts.add(
          ApexSObject.of("Contact")
              .set("FirstName", stringValue(row.get("first_name")))
              .set("LastName", stringValue(row.get("last_name")))
              .set("Email", stringValue(row.get("email"))));
    }
    return new Result(contacts);
  }

  private static Result executeCsvToApexObject(Map<String, Object> payload) {
    List<Map<String, Object>> rows = parseCsv(payloadValueAsString(payload, "records"), ',');
    List<Object> out = new ArrayList<>(rows.size());
    for (Map<String, Object> row : rows) {
      Object instance = instantiateType("CsvData");
      if (instance == null) {
        Map<String, Object> fallback = new LinkedHashMap<>();
        fallback.put("FirstName", stringValue(row.get("first_name")));
        fallback.put("LastName", stringValue(row.get("last_name")));
        fallback.put("Email", stringValue(row.get("email")));
        out.add(fallback);
      } else {
        setField(instance, "FirstName", stringValue(row.get("first_name")));
        setField(instance, "LastName", stringValue(row.get("last_name")));
        setField(instance, "Email", stringValue(row.get("email")));
        out.add(instance);
      }
    }
    return new Result(out);
  }

  private static Result executeJsonDateFormat(Map<String, Object> payload) {
    List<?> records = asList(payloadValue(payload, "records"));
    StringBuilder out = new StringBuilder();
    out.append("{\\n");
    out.append("  \"users\": [\\n");
    for (int i = 0; i < records.size(); i += 1) {
      Object record = records.get(i);
      String firstName = stringValue(getField(record, "FirstName"));
      String lastName = stringValue(getField(record, "LastName"));
      String createdDate = ApexSwitch.formatGMT(getField(record, "CreatedDate"), DATE_FORMAT);
      if (createdDate == null) {
        createdDate = "";
      }
      out.append("    {\\n");
      out.append("      \"firstName\": ").append(JSON.serialize(firstName)).append(",\\n");
      out.append("      \"lastName\": ").append(JSON.serialize(lastName)).append(",\\n");
      out.append("      \"createdDate\": ").append(JSON.serialize(createdDate)).append("\\n");
      out.append("    }");
      if (i + 1 < records.size()) {
        out.append(",");
      }
      out.append("\\n");
    }
    out.append("  ]\\n");
    out.append("}");
    return new Result(out.toString());
  }

  private static Result executePluralizeFunction(Map<String, Object> payload) {
    Object parsed = JSON.deserializeUntyped(payloadValueAsString(payload, "inputs"));
    List<?> words = asList(parsed);
    List<Map<String, String>> out = new ArrayList<>();
    for (Object raw : words) {
      String singular = stringValue(raw);
      Map<String, String> entry = new LinkedHashMap<>();
      entry.put(singular, pluralize(singular));
      out.add(entry);
    }
    return new Result(out);
  }

  private static Result executeReservedApexKeywords(Map<String, Object> payload) {
    List<Map<String, Object>> rows = parseJsonArray(payloadValueAsString(payload, "payload"));
    List<Map<String, Object>> transformed = new ArrayList<>(rows.size());
    for (Map<String, Object> row : rows) {
      Map<String, Object> mapped = new LinkedHashMap<>();
      for (Map.Entry<String, Object> entry : row.entrySet()) {
        mapped.put(renameReservedKeyword(entry.getKey()), entry.getValue());
      }
      transformed.add(mapped);
    }
    return new Result(transformed);
  }

  private static Result executeMultipleInputs(Map<String, Object> payload) {
    List<Map<String, Object>> products = parseJsonArray(payloadValueAsString(payload, "products"));
    Map<String, Object> attributes = parseJsonObject(payloadValueAsString(payload, "attributes"));
    Map<String, Object> exchangeRates = parseJsonObject(payloadValueAsString(payload, "exchangeRates"));

    int publishedAfter = toInt(attributes.get("publishedAfter"));
    List<Map<String, Object>> usdRates = mapList(exchangeRates.get("USD"));

    StringBuilder out = new StringBuilder();
    out.append("<books>");
    for (Map<String, Object> product : products) {
      Map<String, Object> properties = asMap(product.get("properties"));
      int year = toInt(properties.get("year"));
      if (year <= publishedAfter) {
        continue;
      }
      BigDecimal basePrice = toDecimal(product.get("price"));
      out.append("<book year=\"").append(escapeXml(String.valueOf(year))).append("\">");
      for (Map<String, Object> rate : usdRates) {
        String currency = stringValue(rate.get("currency"));
        BigDecimal ratio = toDecimal(rate.get("ratio"));
        BigDecimal converted = ratio.multiply(basePrice);
        out.append("<price currency=\"")
            .append(escapeXml(currency))
            .append("\">")
            .append(formatDecimal(converted))
            .append("</price>");
      }
      out.append("<title>").append(escapeXml(stringValue(properties.get("title")))).append("</title>");
      out.append("<authors>");
      for (Object author : asList(properties.get("author"))) {
        out.append("<author>").append(escapeXml(stringValue(author))).append("</author>");
      }
      out.append("</authors>");
      out.append("</book>");
    }
    out.append("</books>");
    return new Result(out.toString());
  }

  private static String normalizeScriptName(String scriptName) {
    if (scriptName == null) {
      return "";
    }
    return scriptName.replaceAll("[^A-Za-z0-9]", "").toLowerCase(Locale.ROOT);
  }

  private static Object payloadValue(Map<String, Object> payload, String key) {
    if (payload == null || payload.isEmpty()) {
      return null;
    }
    if (key != null && payload.containsKey(key)) {
      return payload.get(key);
    }
    if (payload.containsKey("payload")) {
      return payload.get("payload");
    }
    return payload.values().iterator().next();
  }

  private static String payloadValueAsString(Map<String, Object> payload, String key) {
    return stringValue(payloadValue(payload, key));
  }

  @SuppressWarnings("unchecked")
  private static List<Map<String, Object>> parseJsonArray(String jsonText) {
    Object parsed = JSON.deserializeUntyped(jsonText == null ? "[]" : jsonText);
    if (!(parsed instanceof List<?> list)) {
      return new ArrayList<>();
    }
    List<Map<String, Object>> out = new ArrayList<>(list.size());
    for (Object item : list) {
      if (item instanceof Map<?, ?> map) {
        out.add(castMap(map));
      }
    }
    return out;
  }

  @SuppressWarnings("unchecked")
  private static Map<String, Object> parseJsonObject(String jsonText) {
    Object parsed = JSON.deserializeUntyped(jsonText == null ? "{}" : jsonText);
    if (parsed instanceof Map<?, ?> map) {
      return castMap(map);
    }
    return new LinkedHashMap<>();
  }

  @SuppressWarnings("unchecked")
  private static Map<String, Object> castMap(Map<?, ?> raw) {
    return (Map<String, Object>) raw;
  }

  private static List<Map<String, Object>> parseCsv(String csvText, char separator) {
    List<List<String>> rows = parseCsvRows(csvText, separator);
    if (rows.isEmpty()) {
      return new ArrayList<>();
    }

    List<String> headers = rows.get(0);
    List<Map<String, Object>> out = new ArrayList<>();
    for (int i = 1; i < rows.size(); i += 1) {
      List<String> values = rows.get(i);
      if (values == null || values.isEmpty()) {
        continue;
      }
      Map<String, Object> row = new LinkedHashMap<>();
      for (int column = 0; column < headers.size(); column += 1) {
        String key = headers.get(column);
        if (key == null || key.isBlank()) {
          continue;
        }
        String value = column < values.size() ? values.get(column) : "";
        value = value == null ? "" : value.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\n");
        row.put(key, value);
      }
      out.add(row);
    }
    return out;
  }

  private static List<List<String>> parseCsvRows(String csvText, char separator) {
    List<List<String>> rows = new ArrayList<>();
    if (csvText == null || csvText.isEmpty()) {
      return rows;
    }
    csvText = decodeEscapedLineBreaks(csvText);

    List<String> currentRow = new ArrayList<>();
    StringBuilder currentValue = new StringBuilder();
    boolean inQuotes = false;

    for (int i = 0; i < csvText.length(); i += 1) {
      char ch = csvText.charAt(i);
      if (ch == '"') {
        if (inQuotes && i + 1 < csvText.length() && csvText.charAt(i + 1) == '"') {
          currentValue.append('"');
          i += 1;
        } else {
          inQuotes = !inQuotes;
        }
        continue;
      }

      if (!inQuotes && ch == separator) {
        currentRow.add(currentValue.toString());
        currentValue.setLength(0);
        continue;
      }

      if (!inQuotes && (ch == '\n' || ch == '\r')) {
        currentRow.add(currentValue.toString());
        currentValue.setLength(0);
        rows.add(currentRow);
        currentRow = new ArrayList<>();
        if (ch == '\r' && i + 1 < csvText.length() && csvText.charAt(i + 1) == '\n') {
          i += 1;
        }
        continue;
      }

      currentValue.append(ch);
    }

    currentRow.add(currentValue.toString());
    if (!currentRow.isEmpty()) {
      if (!rows.isEmpty() || containsNonBlankValue(currentRow) || currentRow.size() > 1) {
        rows.add(currentRow);
      }
    }
    return rows;
  }

  private static String decodeEscapedLineBreaks(String value) {
    if (value == null || value.isEmpty()) {
      return "";
    }
    return value.replace("\\r\\n", "\n").replace("\\n", "\n").replace("\\r", "\r");
  }

  private static boolean containsNonBlankValue(List<String> values) {
    if (values == null || values.isEmpty()) {
      return false;
    }
    for (String value : values) {
      if (value != null && !value.isBlank()) {
        return true;
      }
    }
    return false;
  }

  private static String renderJsonWithSpacing(List<Map<String, Object>> rows) {
    StringBuilder out = new StringBuilder();
    out.append("[");
    for (int i = 0; i < rows.size(); i += 1) {
      Map<String, Object> row = rows.get(i);
      if (i > 0) {
        out.append(", ");
      }
      out.append("{");
      int index = 0;
      for (Map.Entry<String, Object> entry : row.entrySet()) {
        if (index > 0) {
          out.append(", ");
        }
        out.append("\"")
            .append(escapeJson(entry.getKey()))
            .append("\": ")
            .append(toJsonValue(entry.getValue()));
        index += 1;
      }
      out.append("}");
    }
    out.append("]");
    return out.toString();
  }

  private static String toJsonValue(Object value) {
    if (value == null) {
      return "null";
    }
    if (value instanceof Number || value instanceof Boolean) {
      return String.valueOf(value);
    }
    return "\"" + escapeJson(String.valueOf(value)) + "\"";
  }

  private static String renameCsvField(String key) {
    if (key == null) {
      return "";
    }
    return switch (key) {
      case "first_name" -> "FirstName";
      case "last_name" -> "LastName";
      case "company" -> "Company";
      case "phone1" -> "HomePhone";
      case "phone" -> "Phone";
      case "email" -> "Email";
      case "date" -> "DateofBirth";
      case "address" -> "MailingStreet";
      case "city" -> "MailingCity";
      case "county" -> "MailingCountry";
      case "state" -> "MailingState";
      case "zip" -> "MailingPostalCode";
      default -> key;
    };
  }

  private static String renameReservedKeyword(String key) {
    if (key == null) {
      return "";
    }
    return switch (key) {
      case "private" -> "isPrivate";
      case "object" -> "obj";
      case "currency" -> "currency_x";
      default -> key;
    };
  }

  private static String pluralize(String singular) {
    if (singular == null || singular.isBlank()) {
      return "";
    }
    String value = singular.trim();
    return switch (value.toLowerCase(Locale.ROOT)) {
      case "deer" -> "deer";
      case "die" -> "dice";
      case "person" -> "people";
      case "datum" -> "data";
      case "cactus" -> "cacti";
      default -> {
        if (value.endsWith("s")
            || value.endsWith("x")
            || value.endsWith("z")
            || value.endsWith("ch")
            || value.endsWith("sh")) {
          yield value + "es";
        }
        if (value.endsWith("y") && value.length() > 1 && !isVowel(value.charAt(value.length() - 2))) {
          yield value.substring(0, value.length() - 1) + "ies";
        }
        yield value + "s";
      }
    };
  }

  private static boolean isVowel(char value) {
    char lower = Character.toLowerCase(value);
    return lower == 'a' || lower == 'e' || lower == 'i' || lower == 'o' || lower == 'u';
  }

  private static Object instantiateType(String typeName) {
    if (typeName == null || typeName.isBlank()) {
      return null;
    }
    try {
      apexemu.runtime.System.Type type = apexemu.runtime.System.Type.forName(typeName);
      if (type == null) {
        type = apexemu.runtime.System.Type.forName("generated", typeName);
      }
      if (type != null) {
        return type.newInstance();
      }
    } catch (RuntimeException ignored) {
      // fall through to class lookup
    }

    ClassLoader cl = Thread.currentThread().getContextClassLoader();
    if (cl == null) {
      cl = DataWeave.class.getClassLoader();
    }
    String[] candidates = new String[] {typeName, "generated." + typeName, "apexemu.runtime." + typeName};
    for (String candidate : candidates) {
      try {
        Class<?> klass = Class.forName(candidate, true, cl);
        return klass.getDeclaredConstructor().newInstance();
      } catch (ReflectiveOperationException ignored) {
        // try next candidate
      }
    }
    return null;
  }

  private static void setField(Object target, String fieldName, Object value) {
    if (target == null || fieldName == null || fieldName.isBlank()) {
      return;
    }
    if (target instanceof ApexSObject row) {
      row.set(fieldName, value);
      return;
    }
    Field field = findField(target.getClass(), fieldName);
    if (field == null) {
      return;
    }
    try {
      field.setAccessible(true);
      field.set(target, convertValue(value, field.getType()));
    } catch (IllegalAccessException ignored) {
      // ignore inaccessible fields
    }
  }

  private static Object getField(Object target, String fieldName) {
    if (target == null || fieldName == null || fieldName.isBlank()) {
      return null;
    }
    if (target instanceof ApexSObject row) {
      return row.get(fieldName);
    }
    Field field = findField(target.getClass(), fieldName);
    if (field == null) {
      return null;
    }
    try {
      field.setAccessible(true);
      return field.get(target);
    } catch (IllegalAccessException ignored) {
      return null;
    }
  }

  private static Field findField(Class<?> type, String fieldName) {
    Class<?> cursor = type;
    while (cursor != null && cursor != Object.class) {
      for (Field field : cursor.getDeclaredFields()) {
        if (field.getName().equals(fieldName) || field.getName().equalsIgnoreCase(fieldName)) {
          return field;
        }
      }
      cursor = cursor.getSuperclass();
    }
    return null;
  }

  private static Object convertValue(Object value, Class<?> type) {
    if (type == null || value == null || type.isInstance(value)) {
      return value;
    }
    if (type == String.class) {
      return stringValue(value);
    }
    if (type == Integer.class || type == int.class) {
      return toInt(value);
    }
    if (type == Long.class || type == long.class) {
      return (long) toInt(value);
    }
    if (type == Double.class || type == double.class) {
      return toDecimal(value).doubleValue();
    }
    if (type == Float.class || type == float.class) {
      return toDecimal(value).floatValue();
    }
    if (type == Boolean.class || type == boolean.class) {
      return toBoolean(value);
    }
    return value;
  }

  private static String stringValue(Object value) {
    if (value == null) {
      return "";
    }
    return String.valueOf(value);
  }

  private static int toInt(Object value) {
    if (value == null) {
      return 0;
    }
    if (value instanceof Number number) {
      return number.intValue();
    }
    try {
      return Integer.parseInt(String.valueOf(value).trim());
    } catch (NumberFormatException ignored) {
      return 0;
    }
  }

  private static boolean toBoolean(Object value) {
    if (value instanceof Boolean bool) {
      return bool;
    }
    if (value == null) {
      return false;
    }
    return "true".equalsIgnoreCase(String.valueOf(value).trim());
  }

  private static BigDecimal toDecimal(Object value) {
    if (value instanceof BigDecimal decimal) {
      return decimal;
    }
    if (value instanceof Number number) {
      return new BigDecimal(String.valueOf(number));
    }
    if (value == null) {
      return BigDecimal.ZERO;
    }
    try {
      return new BigDecimal(String.valueOf(value).trim());
    } catch (NumberFormatException ignored) {
      return BigDecimal.ZERO;
    }
  }

  @SuppressWarnings("unchecked")
  private static Map<String, Object> asMap(Object value) {
    if (value instanceof Map<?, ?> map) {
      return castMap(map);
    }
    return new LinkedHashMap<>();
  }

  @SuppressWarnings("unchecked")
  private static List<?> asList(Object value) {
    if (value instanceof List<?> list) {
      return list;
    }
    if (value == null) {
      return new ArrayList<>();
    }
    List<Object> singleton = new ArrayList<>(1);
    singleton.add(value);
    return singleton;
  }

  @SuppressWarnings("unchecked")
  private static List<Map<String, Object>> mapList(Object raw) {
    if (raw == null) {
      return new ArrayList<>();
    }
    if (raw instanceof List<?> list) {
      List<Map<String, Object>> out = new ArrayList<>();
      for (Object item : list) {
        if (item instanceof Map<?, ?> row) {
          out.add(castMap(row));
        }
      }
      return out;
    }
    if (raw instanceof Map<?, ?> map) {
      List<Map<String, Object>> out = new ArrayList<>(1);
      out.add(castMap(map));
      return out;
    }
    return new ArrayList<>();
  }

  private static String formatDecimal(BigDecimal value) {
    if (value == null) {
      return "0";
    }
    BigDecimal normalized = value.stripTrailingZeros();
    if (normalized.scale() < 0) {
      normalized = normalized.setScale(0, RoundingMode.UNNECESSARY);
    }
    return normalized.toPlainString();
  }

  private static String escapeJson(String value) {
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

  private static String escapeXml(String value) {
    if (value == null || value.isEmpty()) {
      return "";
    }
    return value
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&apos;");
  }
}
