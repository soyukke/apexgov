package apexemu.runtime;

public final class JSONGenerator {
  private final StringBuilder out = new StringBuilder();

  public JSONGenerator() {
    this(false);
  }

  public JSONGenerator(boolean pretty) {
    // pretty flag is ignored in this emulation stub.
  }

  public void writeStartArray() {
    out.append('[');
  }

  public void writeStartObject() {
    out.append('{');
  }

  public void writeFieldName(String name) {
    out.append('"').append(name == null ? "" : name).append('"').append(':');
  }

  public void writeString(String value) {
    out.append(JSON.serialize(value));
  }

  public void writeNumberField(String name, Number value) {
    writeFieldName(name);
    out.append(value == null ? "null" : String.valueOf(value));
  }

  public void writeBooleanField(String name, boolean value) {
    writeFieldName(name);
    out.append(value ? "true" : "false");
  }

  public void writeNull() {
    out.append("null");
  }

  public void writeEndObject() {
    out.append('}');
  }

  public void writeEndArray() {
    out.append(']');
  }

  public String getAsString() {
    return out.toString();
  }
}
