package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;

public final class Schema {
  private static final ThreadLocal<State> STATE = ThreadLocal.withInitial(State::new);

  private Schema() {}

  public static ObjectBuilder object(String type) {
    return new ObjectBuilder(type);
  }

  public static void clear() {
    STATE.set(new State());
  }

  static ObjectDefinition find(String type) {
    if (type == null || type.isBlank()) {
      return null;
    }
    return STATE.get().definitions.get(normalize(type));
  }

  static ChildRelationship resolveChildRelationship(String parentType, String relationshipName) {
    if (parentType == null || parentType.isBlank() || relationshipName == null || relationshipName.isBlank()) {
      return null;
    }

    String normalizedParent = normalize(parentType);
    String normalizedRelationship = normalize(relationshipName);
    ChildRelationship match = null;

    for (ObjectDefinition definition : STATE.get().definitions.values()) {
      if (definition == null || definition.fields == null || definition.fields.isEmpty()) {
        continue;
      }
      for (FieldDefinition field : definition.fields.values()) {
        if (field == null || field.referenceType == null || field.referenceType.isBlank()) {
          continue;
        }
        if (!normalize(field.referenceType).equals(normalizedParent)) {
          continue;
        }
        if (!matchesRelationshipName(definition.type, field, normalizedRelationship)) {
          continue;
        }

        ChildRelationship candidate = new ChildRelationship(definition.type, field.name);
        if (match == null) {
          match = candidate;
        } else if (!sameRelationship(match, candidate)) {
          return null;
        }
      }
    }

    return match;
  }

  static String resolveReferenceField(String rowType, String relationshipSegment) {
    ObjectDefinition definition = find(rowType);
    if (definition == null || relationshipSegment == null || relationshipSegment.isBlank()) {
      return null;
    }
    String normalizedSegment = normalize(relationshipSegment);
    String resolved = null;

    for (FieldDefinition field : definition.fields.values()) {
      if (field == null || field.referenceType == null || field.referenceType.isBlank()) {
        continue;
      }
      if (!matchesReferenceSegment(field, normalizedSegment)) {
        continue;
      }
      if (resolved != null && !resolved.equalsIgnoreCase(field.name)) {
        return null;
      }
      resolved = field.name;
    }
    return resolved;
  }

  private static boolean matchesRelationshipName(
      String childType, FieldDefinition field, String normalizedRelationship) {
    if (field.childRelationshipName != null
        && !field.childRelationshipName.isBlank()
        && normalize(field.childRelationshipName).equals(normalizedRelationship)) {
      return true;
    }

    if (childType != null && !childType.isBlank()) {
      String normalizedChildType = normalize(childType);
      if (normalizedChildType.equals(normalizedRelationship)) {
        return true;
      }

      String plural = pluralizeTypeName(childType);
      if (plural != null && !plural.isBlank() && normalize(plural).equals(normalizedRelationship)) {
        return true;
      }
    }
    return false;
  }

  private static boolean matchesReferenceSegment(FieldDefinition field, String normalizedSegment) {
    if (field == null || normalizedSegment == null || normalizedSegment.isBlank()) {
      return false;
    }

    String fieldName = field.name;
    if (fieldName != null && !fieldName.isBlank()) {
      if (fieldName.length() > 3 && fieldName.regionMatches(true, fieldName.length() - 3, "__c", 0, 3)) {
        String customRelationship = fieldName.substring(0, fieldName.length() - 3) + "__r";
        if (normalize(customRelationship).equals(normalizedSegment)) {
          return true;
        }
      }
      if (fieldName.length() > 2 && fieldName.regionMatches(true, fieldName.length() - 2, "Id", 0, 2)) {
        String standardRelationship = fieldName.substring(0, fieldName.length() - 2);
        if (normalize(standardRelationship).equals(normalizedSegment)) {
          return true;
        }
      }
    }

    if (field.referenceType != null && !field.referenceType.isBlank()) {
      String normalizedReferenceType = normalize(field.referenceType);
      if (normalizedReferenceType.equals(normalizedSegment)) {
        return true;
      }
      if (field.referenceType.length() > 3
          && field.referenceType.regionMatches(true, field.referenceType.length() - 3, "__c", 0, 3)) {
        String customRelationship = field.referenceType.substring(0, field.referenceType.length() - 3) + "__r";
        if (normalize(customRelationship).equals(normalizedSegment)) {
          return true;
        }
      }
    }
    return false;
  }

  private static String pluralizeTypeName(String type) {
    if (type == null || type.isBlank()) {
      return null;
    }
    String trimmed = type.trim();
    if (trimmed.length() > 3 && trimmed.regionMatches(true, trimmed.length() - 3, "__c", 0, 3)) {
      return trimmed.substring(0, trimmed.length() - 3) + "__r";
    }
    if (trimmed.length() > 1 && trimmed.endsWith("y")) {
      return trimmed.substring(0, trimmed.length() - 1) + "ies";
    }
    if (trimmed.endsWith("s")) {
      return trimmed;
    }
    return trimmed + "s";
  }

  private static boolean sameRelationship(ChildRelationship left, ChildRelationship right) {
    if (left == null || right == null) {
      return false;
    }
    return left.childType.equalsIgnoreCase(right.childType)
        && left.parentLinkField.equalsIgnoreCase(right.parentLinkField);
  }

  private static void register(ObjectDefinition definition) {
    STATE.get().definitions.put(normalize(definition.type), definition);
  }

  private static String normalize(String value) {
    return value.trim().toLowerCase();
  }

  public enum FieldType {
    STRING,
    BOOLEAN,
    INTEGER,
    LONG,
    DECIMAL,
    DOUBLE,
    ID
  }

  public static final class ObjectBuilder {
    private final String type;
    private final Map<String, FieldDefinition> fields = new LinkedHashMap<>();

    private ObjectBuilder(String type) {
      if (type == null || type.isBlank()) {
        throw new IllegalArgumentException("sobject type cannot be blank");
      }
      this.type = type.trim();
    }

    public ObjectBuilder required(String field, FieldType type) {
      return define(field, type, true);
    }

    public ObjectBuilder optional(String field, FieldType type) {
      return define(field, type, false);
    }

    public ObjectBuilder requiredPicklist(String field, String... values) {
      return define(field, FieldType.STRING, true).picklist(field, values);
    }

    public ObjectBuilder optionalPicklist(String field, String... values) {
      return define(field, FieldType.STRING, false).picklist(field, values);
    }

    public ObjectBuilder define(String field, FieldType type, boolean required) {
      if (field == null || field.isBlank()) {
        throw new IllegalArgumentException("field cannot be blank");
      }
      if (type == null) {
        throw new IllegalArgumentException("field type cannot be null");
      }
      String canonical = field.trim();
      fields.put(
          normalize(canonical),
          new FieldDefinition(
              canonical, type, required, null, Set.of(), null, null, null, false, false, null));
      return this;
    }

    public ObjectBuilder maxLength(String field, int maxLength) {
      if (maxLength <= 0) {
        throw new IllegalArgumentException("maxLength must be positive");
      }
      FieldDefinition existing = requireDefinedField(field);
      if (existing.type != FieldType.STRING && existing.type != FieldType.ID) {
        throw new IllegalArgumentException(
            "maxLength can be applied only to STRING/ID fields: " + existing.name);
      }
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              Integer.valueOf(maxLength),
              existing.picklistValues,
              existing.precision,
              existing.scale,
              existing.referenceType,
              existing.unique,
              existing.externalId,
              existing.childRelationshipName));
      return this;
    }

    public ObjectBuilder picklist(String field, String... values) {
      FieldDefinition existing = requireDefinedField(field);
      if (existing.type != FieldType.STRING) {
        throw new IllegalArgumentException("picklist can be applied only to STRING fields: " + existing.name);
      }
      Set<String> picklistValues = normalizePicklist(values);
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              existing.maxLength,
              picklistValues,
              existing.precision,
              existing.scale,
              existing.referenceType,
              existing.unique,
              existing.externalId,
              existing.childRelationshipName));
      return this;
    }

    public ObjectBuilder precision(String field, int precision, int scale) {
      if (precision <= 0) {
        throw new IllegalArgumentException("precision must be positive");
      }
      if (scale < 0) {
        throw new IllegalArgumentException("scale cannot be negative");
      }
      if (scale > precision) {
        throw new IllegalArgumentException("scale cannot exceed precision");
      }
      FieldDefinition existing = requireDefinedField(field);
      if (existing.type != FieldType.DECIMAL
          && existing.type != FieldType.DOUBLE
          && existing.type != FieldType.INTEGER
          && existing.type != FieldType.LONG) {
        throw new IllegalArgumentException(
            "precision can be applied only to numeric fields: " + existing.name);
      }
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              existing.maxLength,
              existing.picklistValues,
              Integer.valueOf(precision),
              Integer.valueOf(scale),
              existing.referenceType,
              existing.unique,
              existing.externalId,
              existing.childRelationshipName));
      return this;
    }

    public ObjectBuilder reference(String field, String referenceType) {
      return reference(field, referenceType, null);
    }

    public ObjectBuilder reference(String field, String referenceType, String childRelationshipName) {
      if (referenceType == null || referenceType.isBlank()) {
        throw new IllegalArgumentException("referenceType cannot be blank");
      }
      FieldDefinition existing = requireDefinedField(field);
      if (existing.type != FieldType.ID) {
        throw new IllegalArgumentException("reference can be applied only to ID fields: " + existing.name);
      }
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              existing.maxLength,
              existing.picklistValues,
              existing.precision,
              existing.scale,
              referenceType.trim(),
              existing.unique,
              existing.externalId,
              normalizeBlank(childRelationshipName)));
      return this;
    }

    public ObjectBuilder unique(String field) {
      FieldDefinition existing = requireDefinedField(field);
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              existing.maxLength,
              existing.picklistValues,
              existing.precision,
              existing.scale,
              existing.referenceType,
              true,
              existing.externalId,
              existing.childRelationshipName));
      return this;
    }

    public ObjectBuilder externalId(String field) {
      FieldDefinition existing = requireDefinedField(field);
      if (!supportsExternalIdType(existing.type)) {
        throw new IllegalArgumentException("externalId is not supported for field type: " + existing.type);
      }
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              existing.maxLength,
              existing.picklistValues,
              existing.precision,
              existing.scale,
              existing.referenceType,
              existing.unique,
              true,
              existing.childRelationshipName));
      return this;
    }

    private FieldDefinition requireDefinedField(String field) {
      if (field == null || field.isBlank()) {
        throw new IllegalArgumentException("field cannot be blank");
      }
      String normalized = normalize(field.trim());
      FieldDefinition existing = fields.get(normalized);
      if (existing == null) {
        throw new IllegalArgumentException("field must be defined before applying constraints: " + field);
      }
      return existing;
    }

    private static Set<String> normalizePicklist(String... values) {
      if (values == null || values.length == 0) {
        throw new IllegalArgumentException("picklist values cannot be empty");
      }
      Set<String> out = new LinkedHashSet<>();
      for (String value : values) {
        if (value == null || value.isBlank()) {
          throw new IllegalArgumentException("picklist value cannot be blank");
        }
        out.add(value.trim());
      }
      if (out.isEmpty()) {
        throw new IllegalArgumentException("picklist values cannot be empty");
      }
      return Set.copyOf(out);
    }

    private static boolean supportsExternalIdType(FieldType type) {
      return type == FieldType.STRING
          || type == FieldType.ID
          || type == FieldType.INTEGER
          || type == FieldType.LONG
          || type == FieldType.DECIMAL
          || type == FieldType.DOUBLE;
    }

    private static String normalizeBlank(String value) {
      if (value == null || value.isBlank()) {
        return null;
      }
      return value.trim();
    }

    public void register() {
      Schema.register(new ObjectDefinition(type, Map.copyOf(fields)));
    }
  }

  static final class ObjectDefinition {
    final String type;
    final Map<String, FieldDefinition> fields;

    ObjectDefinition(String type, Map<String, FieldDefinition> fields) {
      this.type = type;
      this.fields = fields;
    }

    FieldDefinition field(String field) {
      if (field == null || field.isBlank()) {
        return null;
      }
      return fields.get(normalize(field));
    }
  }

  static final class FieldDefinition {
    final String name;
    final FieldType type;
    final boolean required;
    final Integer maxLength;
    final Set<String> picklistValues;
    final Integer precision;
    final Integer scale;
    final String referenceType;
    final boolean unique;
    final boolean externalId;
    final String childRelationshipName;

    FieldDefinition(
        String name,
        FieldType type,
        boolean required,
        Integer maxLength,
        Set<String> picklistValues,
        Integer precision,
        Integer scale,
        String referenceType,
        boolean unique,
        boolean externalId,
        String childRelationshipName) {
      this.name = name;
      this.type = type;
      this.required = required;
      this.maxLength = maxLength;
      this.picklistValues = picklistValues == null ? Set.of() : picklistValues;
      this.precision = precision;
      this.scale = scale;
      this.referenceType = referenceType;
      this.unique = unique;
      this.externalId = externalId;
      this.childRelationshipName = childRelationshipName;
    }
  }

  static final class ChildRelationship {
    final String childType;
    final String parentLinkField;

    ChildRelationship(String childType, String parentLinkField) {
      this.childType = childType;
      this.parentLinkField = parentLinkField;
    }
  }

  private static final class State {
    final Map<String, ObjectDefinition> definitions = new LinkedHashMap<>();
  }
}
