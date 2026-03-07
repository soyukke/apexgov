package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public class Contact {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("Contact");
  public static final Schema.SObjectField Id = new Schema.SObjectField("Contact", "Id");
  public static final Schema.SObjectField Name = new Schema.SObjectField("Contact", "Name");
  public static final Schema.SObjectField Title = new Schema.SObjectField("Contact", "Title");
  // Apex source can reference this token with lowercase name.
  public static final Schema.SObjectField title = Title;
  public static final Schema.SObjectField LastName = new Schema.SObjectField("Contact", "LastName");
  public static final Schema.SObjectField FirstName = new Schema.SObjectField("Contact", "FirstName");
  public static final Schema.SObjectField Email = new Schema.SObjectField("Contact", "Email");
  public static final Schema.SObjectField OwnerId = new Schema.SObjectField("Contact", "OwnerId");
  public static final Schema.SObjectField LastModifiedById =
      new Schema.SObjectField("Contact", "LastModifiedById");
  public static final Schema.SObjectField LastModifiedDate =
      new Schema.SObjectField("Contact", "LastModifiedDate");
  public static final Schema.SObjectField CreatedDate =
      new Schema.SObjectField("Contact", "CreatedDate");
  public static final Schema.SObjectField Birthdate =
      new Schema.SObjectField("Contact", "Birthdate");
  public static final Schema.SObjectField AccountId =
      new Schema.SObjectField("Contact", "AccountId");

  private final Map<String, Object> fields = new LinkedHashMap<>();

  public Contact set(String field, Object value) {
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
