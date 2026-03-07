package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public class CaseComment {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("CaseComment");
  // Some transpiled tests reference lowercase alias.
  public static final Schema.SObjectType sObjectType = SObjectType;
  public static final Schema.SObjectField Id = new Schema.SObjectField("CaseComment", "Id");
  public static final Schema.SObjectField CommentBody =
      new Schema.SObjectField("CaseComment", "CommentBody");

  private final Map<String, Object> fields = new LinkedHashMap<>();

  public CaseComment set(String field, Object value) {
    if (field == null || field.isBlank()) {
      return this;
    }
    fields.put(field, value);
    return this;
  }

  public Object get(String field) {
    if (field == null) {
      return null;
    }
    for (Map.Entry<String, Object> entry : fields.entrySet()) {
      if (entry.getKey().equalsIgnoreCase(field)) {
        return entry.getValue();
      }
    }
    return null;
  }

  @SuppressWarnings("unchecked")
  public <T> T getAs(String field) {
    return (T) get(field);
  }

  public static Schema.SObjectType getSObjectType() {
    return SObjectType;
  }
}
