package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

public class ApexSObject {
  public final String type;
  public String Id;
  public Object description;
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

  @SuppressWarnings("unchecked")
  public static <T extends ApexSObject> T of(String type) {
    return (T) instantiateByType(type);
  }

  private static ApexSObject instantiateByType(String type) {
    if (type == null || type.isBlank()) {
      return new ApexSObject(type);
    }
    String normalizedType = type.trim();
    try {
      Class<?> runtimeType = Class.forName("apexemu.runtime." + normalizedType);
      if (ApexSObject.class.isAssignableFrom(runtimeType)) {
        java.lang.reflect.Constructor<?> ctor = runtimeType.getDeclaredConstructor();
        ctor.setAccessible(true);
        return (ApexSObject) ctor.newInstance();
      }
    } catch (ReflectiveOperationException | LinkageError ignored) {
      // Fallback to generic dynamic record when no concrete runtime type exists.
    }
    return new ApexSObject(normalizedType);
  }

  public static Map<String, ApexSObject> getAll(String type) {
    if (type == null || type.isBlank()) {
      return new LinkedHashMap<>();
    }
    List<ApexSObject> rows;
    try {
      rows = ApexStore.query("SELECT Id, Name FROM " + type.trim());
    } catch (RuntimeException ignored) {
      return new LinkedHashMap<>();
    }
    Map<String, ApexSObject> out = new LinkedHashMap<>();
    for (ApexSObject row : rows) {
      if (row == null) {
        continue;
      }
      Object key = row.get("Name");
      if (key == null) {
        key = row.get("Id");
      }
      if (key == null) {
        continue;
      }
      out.put(String.valueOf(key), row);
    }
    return out;
  }

  public String type() {
    return type;
  }

  public int size() {
    Object records = get("records");
    if (records instanceof java.util.Collection<?> collection) {
      return collection.size();
    }
    return fields.size();
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

  public String getRecordTypeId() {
    Object value = get("RecordTypeId");
    if (value == null) {
      value = get("Id");
    }
    return value == null ? null : String.valueOf(value);
  }

  public String getName() {
    Object value = get("Name");
    return value == null ? null : String.valueOf(value);
  }

  public boolean isAvailable() {
    Object value = get("IsAvailable");
    if (value instanceof Boolean flag) {
      return flag;
    }
    return true;
  }

  public boolean isDefaultRecordTypeMapping() {
    Object value = get("IsDefaultRecordTypeMapping");
    if (value instanceof Boolean flag) {
      return flag;
    }
    return false;
  }

  public boolean isActive() {
    Object value = get("IsActive");
    if (value instanceof Boolean flag) {
      return flag;
    }
    return isAvailable();
  }

  public boolean isMaster() {
    Object name = get("Name");
    return name != null && "Master".equalsIgnoreCase(String.valueOf(name));
  }

  public String getDeveloperName() {
    Object value = get("DeveloperName");
    return value == null ? null : String.valueOf(value);
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
    if (normalizedField.equalsIgnoreCase("description")) {
      this.description = value;
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
    if (field.equalsIgnoreCase("description") && description != null) {
      return description;
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
      String normalized = field.trim();
      if (normalized.endsWith("__r")) {
        return new ArrayList<ApexSObject>();
      }
      if (normalized.endsWith("__c") || normalized.contains("__r.")) {
        return null;
      }
      throw new SObjectException(
          "row was retrieved via SOQL without querying the requested field: " + field);
    }
    return null;
  }

  @SuppressWarnings("unchecked")
  public <T> T getAs(String field) {
    Object value = get(field);
    return (T) coerceTemporalValue(field, value);
  }

  private static Object coerceTemporalValue(String field, Object value) {
    if (!(value instanceof String text) || field == null || field.isBlank()) {
      return value;
    }
    String trimmed = text.trim();
    if (!looksLikeIsoDateOrDateTime(trimmed)) {
      return value;
    }
    String normalizedField = field.trim().toLowerCase(Locale.ROOT);

    if (isLikelyDateTimeField(normalizedField)) {
      DateTime dateTime = DateTime.valueOf(trimmed);
      return dateTime == null ? value : dateTime;
    }
    if (isLikelyDateField(normalizedField)) {
      if (trimmed.length() >= 10) {
        try {
          Date parsed = Date.valueOf(trimmed.substring(0, 10));
          if (parsed != null) {
            return parsed;
          }
        } catch (RuntimeException ignored) {
          // fall through
        }
      }
      Date parsed = Date.valueOf(trimmed);
      return parsed == null ? value : parsed;
    }
    return value;
  }

  private static boolean looksLikeIsoDateOrDateTime(String value) {
    if (value == null || value.length() < 10) {
      return false;
    }
    // Fast path for `yyyy-MM-dd` with optional time suffix.
    return Character.isDigit(value.charAt(0))
        && Character.isDigit(value.charAt(1))
        && Character.isDigit(value.charAt(2))
        && Character.isDigit(value.charAt(3))
        && value.charAt(4) == '-'
        && Character.isDigit(value.charAt(5))
        && Character.isDigit(value.charAt(6))
        && value.charAt(7) == '-'
        && Character.isDigit(value.charAt(8))
        && Character.isDigit(value.charAt(9));
  }

  private static boolean isLikelyDateTimeField(String normalizedField) {
    if (normalizedField == null || normalizedField.isBlank()) {
      return false;
    }
    return normalizedField.endsWith("datetime")
        || normalizedField.endsWith("datetime__c")
        || normalizedField.endsWith("datetime__pc")
        || normalizedField.equals("createddate")
        || normalizedField.equals("lastmodifieddate")
        || normalizedField.equals("systemmodstamp")
        || normalizedField.equals("completeddate");
  }

  private static boolean isLikelyDateField(String normalizedField) {
    if (normalizedField == null || normalizedField.isBlank()) {
      return false;
    }
    if (isLikelyDateTimeField(normalizedField)) {
      return false;
    }
    return normalizedField.endsWith("date")
        || normalizedField.endsWith("date__c")
        || normalizedField.endsWith("date__pc")
        || normalizedField.contains("_date__");
  }

  public Object get(Object field) {
    if (field instanceof Schema.SObjectField token) {
      return get(resolveFieldName(token));
    }
    if (field == null) {
      return null;
    }
    return get(String.valueOf(field));
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

  public ApexSObject Clone(
      boolean preserveId,
      boolean isDeepClone,
      boolean preserveReadonlyTimestamps,
      boolean preserveAutonumber) {
    return clone(preserveId, isDeepClone, preserveReadonlyTimestamps, preserveAutonumber);
  }

  public ApexSObject Clone(boolean preserveId) {
    return clone(preserveId);
  }

  public ApexSObject Clone(boolean preserveId, boolean isDeepClone) {
    return clone(preserveId, isDeepClone);
  }

  public ApexSObject Clone(
      boolean preserveId, boolean isDeepClone, boolean preserveReadonlyTimestamps) {
    return clone(preserveId, isDeepClone, preserveReadonlyTimestamps);
  }

  public ApexSObject Clone() {
    return clone();
  }

  public void addError(String message) {
    validationErrors.add(
        new Database.Error(
            "FIELD_CUSTOM_VALIDATION_EXCEPTION",
            message == null ? "sobject validation error" : message));
  }

  public void addError(Object message) {
    addError(message == null ? null : String.valueOf(message));
  }

  public void addError(String message, boolean escape) {
    addError(message);
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

  public void put(Object field, Object value) {
    if (field instanceof Schema.SObjectField token) {
      set(resolveFieldName(token), value);
      return;
    }
    if (field == null) {
      return;
    }
    put(String.valueOf(field), value);
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
