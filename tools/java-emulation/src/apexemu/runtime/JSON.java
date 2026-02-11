package apexemu.runtime;

import java.util.Map;

public final class JSON {
  private JSON() {}

  public static String serialize(Object value) {
    if (value == null) {
      return "null";
    }
    if (value instanceof String s) {
      return "\"" + escape(s) + "\"";
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
    return "\"" + escape(String.valueOf(value)) + "\"";
  }

  public static String serializePretty(Object value) {
    return serialize(value);
  }

  public static <T> T deserialize(String payload, Class<T> clazz) {
    throw new UnsupportedOperationException("deserialize is not implemented in local emulation");
  }

  public static Object deserializeUntyped(String payload) {
    if (payload == null) {
      return null;
    }
    return payload;
  }

  public static <T> T deserializeStrict(String payload, Class<T> clazz) {
    return deserialize(payload, clazz);
  }

  public static Parser createParser(String payload) {
    return new Parser(payload);
  }

  public static Generator createGenerator(boolean pretty) {
    return new Generator();
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
