package apexemu.runtime;

public final class JSONParser {
  public enum Token {
    START_ARRAY,
    START_OBJECT,
    FIELD_NAME,
    VALUE_STRING,
    VALUE_FALSE,
    VALUE_TRUE,
    VALUE_NUMBER_FLOAT,
    VALUE_NUMBER_INT,
    VALUE_NULL,
    END_OBJECT,
    END_ARRAY
  }

  private final String payload;

  public JSONParser(String payload) {
    this.payload = payload == null ? "" : payload;
  }

  public Token nextToken() {
    return null;
  }

  public Token getCurrentToken() {
    return null;
  }

  public String getCurrentName() {
    return null;
  }

  public String getText() {
    return null;
  }

  public Integer getIntegerValue() {
    String text = getText();
    if (text == null) {
      return null;
    }
    String trimmed = text.trim();
    if (trimmed.isEmpty()) {
      return null;
    }
    try {
      return Integer.valueOf(trimmed);
    } catch (NumberFormatException ignored) {
      try {
        return (int) Double.parseDouble(trimmed);
      } catch (NumberFormatException ignoredAgain) {
        return null;
      }
    }
  }

  public Integer getIntValue() {
    return getIntegerValue();
  }

  public String getPayload() {
    return payload;
  }
}
