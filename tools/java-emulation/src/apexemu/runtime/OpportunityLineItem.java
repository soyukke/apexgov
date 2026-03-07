package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public class OpportunityLineItem {
  public static final Schema.SObjectType SObjectType =
      new Schema.SObjectType("OpportunityLineItem");
  public static final Schema.SObjectField OpportunityId =
      new Schema.SObjectField("OpportunityLineItem", "OpportunityId");
  public static final Schema.SObjectField PricebookEntryId =
      new Schema.SObjectField("OpportunityLineItem", "PricebookEntryId");

  private final Map<String, Object> fields = new LinkedHashMap<>();

  public OpportunityLineItem set(String field, Object value) {
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
