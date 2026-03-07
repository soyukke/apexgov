package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

public class ApexSObject {
  private final String type;
  public String Id;
  private final Map<String, Object> fields = new LinkedHashMap<>();
  private boolean strictQueryAccess = false;
  private final Set<String> queriedFieldsLower = new LinkedHashSet<>();
  private final List<Database.Error> validationErrors = new ArrayList<>();

  ApexSObject(String type) {
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
    return Id;
  }

  public Schema.SObjectType getSObjectType() {
    return new Schema.SObjectType(type);
  }

  public Schema.SObjectType getSobjectType() {
    return getSObjectType();
  }

  public ApexSObject withId(String id) {
    if (id == null || id.isBlank()) {
      this.Id = null;
    } else {
      this.Id = id.trim();
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
        this.Id = null;
      } else {
        String nextId = String.valueOf(value).trim();
        this.Id = nextId.isEmpty() ? null : nextId;
      }
      return this;
    }
    // Remove existing key with different case to prevent duplicates
    fields.keySet().removeIf(key -> key.equalsIgnoreCase(normalizedField) && !key.equals(normalizedField));
    fields.put(normalizedField, value);
    return this;
  }

  public Object get(String field) {
    if (field == null) {
      return null;
    }
    if (field.indexOf('.') >= 0) {
      Object current = this;
      for (String segment : field.split("\\.")) {
        if (segment == null || segment.isBlank()) {
          continue;
        }
        if (current instanceof ApexSObject row) {
          current = row.get(segment);
        } else {
          current = ApexSwitch.getAs(current, segment);
        }
        if (current == null) {
          return null;
        }
      }
      return current;
    }
    if (field.equalsIgnoreCase("id")) {
      return Id;
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
    if (strictQueryAccess && !isFieldQueryable(field)) {
      if (isKnownChildRelationship(field)) {
        return new ArrayList<ApexSObject>();
      }
      throw new SObjectException(
          "row was retrieved via SOQL without querying the requested field: " + field);
    }
    return null;
  }

  @SuppressWarnings("unchecked")
  public <T> T getAs(String field) {
    return (T) get(field);
  }

  public Object get(Schema.SObjectField field) {
    return get(resolveFieldName(field));
  }

  public boolean hasField(String field) {
    if (field == null) {
      return false;
    }
    if (field.equalsIgnoreCase("id")) {
      return Id != null;
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

  public Map<String, Object> getPopulatedFieldsAsMap() {
    Map<String, Object> out = new LinkedHashMap<>();
    if (Id != null) {
      out.put("Id", Id);
    }
    out.putAll(fields);
    return out;
  }

  public List<ApexSObject> getSObjects(String relationshipName) {
    Object raw = get(relationshipName);
    if (!(raw instanceof Iterable<?> iterable)) {
      return new ArrayList<>();
    }
    List<ApexSObject> out = new ArrayList<>();
    for (Object item : iterable) {
      if (item instanceof ApexSObject row) {
        out.add(row);
      }
    }
    return out;
  }

  public List<ApexSObject> getSobjects(String relationshipName) {
    return getSObjects(relationshipName);
  }

  public ApexSObject getSObject(String relationshipName) {
    Object raw = get(relationshipName);
    if (raw instanceof ApexSObject row) {
      return row;
    }
    return null;
  }

  public ApexSObject getSobject(String relationshipName) {
    return getSObject(relationshipName);
  }

  ApexSObject copy() {
    ApexSObject out = ApexSObject.of(this.type);
    out.Id = this.Id;
    out.fields.putAll(this.fields);
    out.strictQueryAccess = this.strictQueryAccess;
    out.queriedFieldsLower.addAll(this.queriedFieldsLower);
    return out;
  }

  /** Retain only the specified fields (case-insensitive). Id is always retained. */
  void retainFields(Set<String> fieldNamesLower) {
    fields.keySet().removeIf(k -> !fieldNamesLower.contains(k.toLowerCase()));
  }

  void markQueriedFields(Set<String> fieldNamesLower) {
    strictQueryAccess = true;
    queriedFieldsLower.clear();
    if (fieldNamesLower == null || fieldNamesLower.isEmpty()) {
      return;
    }
    for (String field : fieldNamesLower) {
      if (field == null || field.isBlank()) {
        continue;
      }
      queriedFieldsLower.add(field.toLowerCase());
    }
  }

  boolean hasStrictQueryAccess() {
    return strictQueryAccess;
  }

  Set<String> queriedFieldsLower() {
    return new LinkedHashSet<>(queriedFieldsLower);
  }

  private boolean isFieldQueryable(String field) {
    if (field == null || field.isBlank()) {
      return true;
    }
    String lowered = field.toLowerCase();
    if (queriedFieldsLower.contains(lowered)) {
      return true;
    }
    if (lowered.contains(".")) {
      String segment = lowered.substring(0, lowered.indexOf('.'));
      return queriedFieldsLower.contains(segment);
    }
    return false;
  }

  private boolean isKnownChildRelationship(String field) {
    if (field == null || field.isBlank()) {
      return false;
    }
    try {
      for (Schema.ChildRelationship relationship : getSObjectType().getDescribe().getChildRelationships()) {
        if (relationship == null) {
          continue;
        }
        String relationshipName = relationship.getRelationshipName();
        if (relationshipName != null && relationshipName.equalsIgnoreCase(field)) {
          return true;
        }
      }
    } catch (RuntimeException ignored) {
      return false;
    }
    return false;
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

  public ApexSObject clone(boolean preserveId) {
    return clone(preserveId, true, false, false);
  }

  public ApexSObject clone(boolean preserveId, boolean isDeepClone) {
    return clone(preserveId, isDeepClone, false, false);
  }

  public ApexSObject clone() {
    return clone(true, true, false, false);
  }

  public ApexSObject clone(
      boolean preserveId, boolean isDeepClone, boolean preserveReadonlyTimestamps) {
    return clone(preserveId, isDeepClone, preserveReadonlyTimestamps, false);
  }

  public void addError(String message) {
    validationErrors.add(
        new Database.Error(
            "FIELD_CUSTOM_VALIDATION_EXCEPTION",
            message == null ? "sobject validation error" : message));
  }

  public void addError(Schema.SObjectField field, String message) {
    addError(message);
  }

  public void addError(String fieldName, String message) {
    addError(message);
  }

  boolean hasErrors() {
    return !validationErrors.isEmpty();
  }

  Database.Error[] getErrors() {
    return validationErrors.toArray(new Database.Error[0]);
  }

  void clearErrors() {
    validationErrors.clear();
  }

  public ApexSObject set(Schema.SObjectField field, Object value) {
    return set(resolveFieldName(field), value);
  }

  public void put(String field, Object value) {
    set(field, value);
  }

  public void put(Schema.SObjectField field, Object value) {
    set(field, value);
  }

  public void putSObject(String relationshipName, ApexSObject value) {
    set(relationshipName, value);
  }

  @Override
  public boolean equals(Object other) {
    if (this == other) {
      return true;
    }
    if (!(other instanceof ApexSObject row)) {
      return false;
    }
    if (!type.equalsIgnoreCase(row.type)) {
      return false;
    }

    String thisId = normalizedId(Id);
    String otherId = normalizedId(row.Id);
    if (thisId != null && otherId != null) {
      return thisId.equalsIgnoreCase(otherId);
    }
    if (thisId != null || otherId != null) {
      return false;
    }

    return fieldsEqual(row.fields);
  }

  @Override
  public int hashCode() {
    int result = type.toLowerCase(java.util.Locale.ROOT).hashCode();
    String thisId = normalizedId(Id);
    if (thisId != null) {
      result = 31 * result + thisId.toLowerCase(java.util.Locale.ROOT).hashCode();
      return result;
    }

    List<String> keys = new ArrayList<>(fields.keySet());
    keys.sort(String.CASE_INSENSITIVE_ORDER);
    for (String key : keys) {
      String normalized = key == null ? "" : key.toLowerCase(java.util.Locale.ROOT);
      result = 31 * result + normalized.hashCode();
      result = 31 * result + Objects.hashCode(fields.get(key));
    }
    return result;
  }

  private static String resolveFieldName(Schema.SObjectField field) {
    if (field == null) {
      return null;
    }
    String name = field.getName();
    if (name == null || name.isBlank()) {
      return String.valueOf(field);
    }
    return name;
  }

  private static String normalizedId(String id) {
    if (id == null) {
      return null;
    }
    String normalized = id.trim();
    return normalized.isEmpty() ? null : normalized;
  }

  private boolean fieldsEqual(Map<String, Object> otherFields) {
    if (fields.size() != otherFields.size()) {
      return false;
    }
    for (Map.Entry<String, Object> entry : fields.entrySet()) {
      String key = entry.getKey();
      Object thisValue = entry.getValue();
      Object otherValue = findFieldValue(otherFields, key);
      if (!Objects.equals(thisValue, otherValue)) {
        return false;
      }
    }
    return true;
  }

  private static Object findFieldValue(Map<String, Object> source, String fieldName) {
    if (fieldName == null) {
      return null;
    }
    for (Map.Entry<String, Object> entry : source.entrySet()) {
      String key = entry.getKey();
      if (key != null && key.equalsIgnoreCase(fieldName)) {
        return entry.getValue();
      }
    }
    return null;
  }
}
