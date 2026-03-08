package apexemu.runtime;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public final class Labels {
  private static final Map<String, String> VALUES = new ConcurrentHashMap<>();

  private Labels() {}

  public static String get(String name) {
    if (name == null || name.isBlank()) {
      return "";
    }
    String key = normalizeKey(null, name);
    return VALUES.getOrDefault(key, name);
  }

  public static String getAs(String name) {
    return get(name);
  }

  public static Namespace namespace(String namespace) {
    return new Namespace(namespace);
  }

  public static void put(String name, String value) {
    if (name == null || name.isBlank()) {
      return;
    }
    VALUES.put(normalizeKey(null, name), value == null ? "" : value);
  }

  public static void put(String namespace, String name, String value) {
    if (name == null || name.isBlank()) {
      return;
    }
    VALUES.put(normalizeKey(namespace, name), value == null ? "" : value);
  }

  private static String normalizeKey(String namespace, String name) {
    String normalizedName = name == null ? "" : name.trim();
    if (namespace == null || namespace.isBlank()) {
      return normalizedName;
    }
    return namespace.trim() + "." + normalizedName;
  }

  public static final class Namespace {
    private final String namespace;

    private Namespace(String namespace) {
      this.namespace = namespace == null ? "" : namespace.trim();
    }

    public String get(String name) {
      if (name == null || name.isBlank()) {
        return "";
      }
      String key = normalizeKey(namespace, name);
      return VALUES.getOrDefault(key, key);
    }

    public String getAs(String name) {
      return get(name);
    }
  }
}
