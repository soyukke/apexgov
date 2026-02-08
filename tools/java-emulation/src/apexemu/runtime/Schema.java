package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

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

    public ObjectBuilder define(String field, FieldType type, boolean required) {
      if (field == null || field.isBlank()) {
        throw new IllegalArgumentException("field cannot be blank");
      }
      if (type == null) {
        throw new IllegalArgumentException("field type cannot be null");
      }
      String canonical = field.trim();
      fields.put(normalize(canonical), new FieldDefinition(canonical, type, required));
      return this;
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

    FieldDefinition(String name, FieldType type, boolean required) {
      this.name = name;
      this.type = type;
      this.required = required;
    }
  }

  private static final class State {
    final Map<String, ObjectDefinition> definitions = new LinkedHashMap<>();
  }
}
