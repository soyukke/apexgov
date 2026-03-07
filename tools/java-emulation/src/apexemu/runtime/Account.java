package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public class Account {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("Account");
  public static final Schema.SObjectField Id = new Schema.SObjectField("Account", "Id");
  public static final Schema.SObjectField Name = new Schema.SObjectField("Account", "Name");
  public static final Schema.SObjectField AccountNumber =
      new Schema.SObjectField("Account", "AccountNumber");
  public static final Schema.SObjectField AnnualRevenue =
      new Schema.SObjectField("Account", "AnnualRevenue");
  public static final Schema.SObjectField Description =
      new Schema.SObjectField("Account", "Description");
  public static final Schema.SObjectField Rating = new Schema.SObjectField("Account", "Rating");
  public static final Schema.SObjectField ShippingStreet =
      new Schema.SObjectField("Account", "ShippingStreet");
  public static final Schema.SObjectField ShippingCountry =
      new Schema.SObjectField("Account", "ShippingCountry");
  public static final Schema.SObjectField ShippingAddress =
      new Schema.SObjectField("Account", "ShippingAddress");
  public static final Schema.SObjectField TradeStyle =
      new Schema.SObjectField("Account", "TradeStyle");
  public static final Schema.SObjectField Tradestyle =
      new Schema.SObjectField("Account", "Tradestyle");
  public static final Schema.SObjectField CreatedById =
      new Schema.SObjectField("Account", "CreatedById");
  public static final Schema.SObjectField LastReferencedDate =
      new Schema.SObjectField("Account", "LastReferencedDate");
  public static final Schema.SObjectField IsDeleted =
      new Schema.SObjectField("Account", "IsDeleted");

  private final Map<String, Object> fields = new LinkedHashMap<>();

  public Account set(String field, Object value) {
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
