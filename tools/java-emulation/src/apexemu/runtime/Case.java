package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public class Case {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("Case");
  public static final Schema.SObjectField Id = new Schema.SObjectField("Case", "Id");
  public static final Schema.SObjectField CaseNumber = new Schema.SObjectField("Case", "CaseNumber");
  public static final Schema.SObjectField Subject = new Schema.SObjectField("Case", "Subject");
  public static final Schema.SObjectField OwnerId = new Schema.SObjectField("Case", "OwnerId");

  private final Map<String, Object> fields = new LinkedHashMap<>();

  public Case set(String field, Object value) {
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
