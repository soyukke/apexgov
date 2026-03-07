package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public class Opportunity {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("Opportunity");
  public static final Schema.SObjectField Id = new Schema.SObjectField("Opportunity", "Id");
  public static final Schema.SObjectField Name = new Schema.SObjectField("Opportunity", "Name");
  public static final Schema.SObjectField Type = new Schema.SObjectField("Opportunity", "Type");
  public static final Schema.SObjectField Amount = new Schema.SObjectField("Opportunity", "Amount");
  public static final Schema.SObjectField StageName =
      new Schema.SObjectField("Opportunity", "StageName");
  public static final Schema.SObjectField CloseDate =
      new Schema.SObjectField("Opportunity", "CloseDate");
  public static final Schema.SObjectField CreatedDate =
      new Schema.SObjectField("Opportunity", "CreatedDate");
  public static final Schema.SObjectField LastModifiedDate =
      new Schema.SObjectField("Opportunity", "LastModifiedDate");
  public static final Schema.SObjectField AccountId = new Schema.SObjectField("Opportunity", "AccountId");

  private final Map<String, Object> fields = new LinkedHashMap<>();

  public Opportunity set(String field, Object value) {
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
