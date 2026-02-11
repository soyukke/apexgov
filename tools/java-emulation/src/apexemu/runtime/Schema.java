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
          normalize(canonical), new FieldDefinition(canonical, type, required, null, Set.of()));
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
              existing.picklistValues));
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
              picklistValues));
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

    FieldDefinition(
        String name, FieldType type, boolean required, Integer maxLength, Set<String> picklistValues) {
      this.name = name;
      this.type = type;
      this.required = required;
      this.maxLength = maxLength;
      this.picklistValues = picklistValues == null ? Set.of() : picklistValues;
    }
  }

  private static final class State {
    final Map<String, ObjectDefinition> definitions = new LinkedHashMap<>();
  }
}
