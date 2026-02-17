package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public final class ApexSObject {
  private final String type;
  private String id;
  private final Map<String, Object> fields = new LinkedHashMap<>();

  private ApexSObject(String type) {
    if (type == null || type.isBlank()) {
      throw new IllegalArgumentException("sobject type cannot be blank");
    }
    this.type = type.trim();
  }

  public static ApexSObject of(String type) {
    return new ApexSObject(type);
  }

  public String type() {
    return type;
  }

  public String id() {
    return id;
  }

  public ApexSObject withId(String id) {
    if (id == null || id.isBlank()) {
      this.id = null;
    } else {
      this.id = id.trim();
    }
    return this;
  }

  public ApexSObject set(String field, Object value) {
    if (field == null || field.isBlank()) {
      throw new IllegalArgumentException("field cannot be blank");
    }
    String normalizedField = field.trim();
    if (normalizedField.equalsIgnoreCase("id")) {
      if (value == null) {
        this.id = null;
      } else {
        String nextId = String.valueOf(value).trim();
        this.id = nextId.isEmpty() ? null : nextId;
      }
      return this;
    }
    fields.put(normalizedField, value);
    return this;
  }

  public Object get(String field) {
    if (field == null) {
      return null;
    }
    if (field.equalsIgnoreCase("id")) {
      return id;
    }
    for (Map.Entry<String, Object> entry : fields.entrySet()) {
      if (entry.getKey().equalsIgnoreCase(field)) {
        return entry.getValue();
      }
    }
    if (field.equalsIgnoreCase("name")) {
      Object firstName = get("FirstName");
      Object lastName = get("LastName");
      String firstText = firstName == null ? "" : String.valueOf(firstName).trim();
      String lastText = lastName == null ? "" : String.valueOf(lastName).trim();
      String joined = (firstText + " " + lastText).trim();
      if (!joined.isEmpty()) {
        return joined;
      }
    }
    return null;
  }

  @SuppressWarnings("unchecked")
  public <T> T getAs(String field) {
    return (T) get(field);
  }

  public boolean hasField(String field) {
    if (field == null) {
      return false;
    }
    if (field.equalsIgnoreCase("id")) {
      return id != null;
    }
    for (String key : fields.keySet()) {
      if (key.equalsIgnoreCase(field)) {
        return true;
      }
    }
    return false;
  }

  public Map<String, Object> fields() {
    return java.util.Collections.unmodifiableMap(fields);
  }

  ApexSObject copy() {
    ApexSObject out = ApexSObject.of(this.type);
    out.id = this.id;
    out.fields.putAll(this.fields);
    return out;
  }

  public ApexSObject clone(
      boolean preserveId,
      boolean isDeepClone,
      boolean preserveReadonlyTimestamps,
      boolean preserveAutonumber) {
    ApexSObject out = copy();
    if (!preserveId) {
      out.withId(null);
    }
    return out;
  }
}
