package apexemu.runtime;

public final class JSONGenerator {
  private final StringBuilder out = new StringBuilder();
  private boolean needsComma = false;

  public JSONGenerator() {
    this(false);
  }

  public JSONGenerator(boolean pretty) {
    // pretty flag is ignored in this emulation stub.
  }

  public void writeStartArray() {
    maybeComma();
    out.append('[');
    needsComma = false;
  }

  public void writeStartObject() {
    maybeComma();
    out.append('{');
    needsComma = false;
  }

  public void writeFieldName(String name) {
    maybeComma();
    out.append('"').append(name == null ? "" : name).append('"').append(':');
    needsComma = false;
  }

  public void writeString(String value) {
    maybeComma();
    out.append(JSON.serialize(value));
    needsComma = true;
  }

  public void writeStringField(String name, String value) {
    writeFieldName(name);
    out.append(JSON.serialize(value));
    needsComma = true;
  }

  public void writeNumberField(String name, Number value) {
    writeFieldName(name);
    out.append(value == null ? "null" : String.valueOf(value));
    needsComma = true;
  }

  public void writeBooleanField(String name, boolean value) {
    writeFieldName(name);
    out.append(value ? "true" : "false");
    needsComma = true;
  }

  public void writeNull() {
    maybeComma();
    out.append("null");
    needsComma = true;
  }

  public void writeNullField(String name) {
    writeFieldName(name);
    out.append("null");
    needsComma = true;
  }

  public void writeEndObject() {
    out.append('}');
    needsComma = true;
  }

  public void writeEndArray() {
    out.append(']');
    needsComma = true;
  }

  public String getAsString() {
    return out.toString();
  }

  private void maybeComma() {
    if (needsComma) {
      out.append(',');
    }
  }
}
