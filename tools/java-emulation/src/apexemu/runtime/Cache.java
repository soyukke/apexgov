package apexemu.runtime;

import java.lang.reflect.InvocationTargetException;
import java.util.ArrayList;
import java.util.Map;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;

public final class Cache {
  private static final Map<String, OrgPartition> ORG_PARTITIONS = new ConcurrentHashMap<>();
  private static final Map<String, SessionPartition> SESSION_PARTITIONS = new ConcurrentHashMap<>();

  private Cache() {}

  public static void clearAll() {
    ORG_PARTITIONS.clear();
    SESSION_PARTITIONS.clear();
  }

  public interface CacheBuilder {
    Object doLoad(String key);
  }

  public enum Visibility {
    NAMESPACE,
    ALL
  }

  public static class Partition {
    protected final Map<String, Object> values = new ConcurrentHashMap<>();

    public Object get(String key) {
      return values.get(key);
    }

    @SuppressWarnings("unchecked")
    public <T> T get(Class<? extends CacheBuilder> builderType, String key) {
      if (builderType == null) {
        return (T) values.get(key);
      }
      String scopedKey = builderScopedKey(builderType, key);
      Object existing = values.get(scopedKey);
      if (existing == null && key != null) {
        Object legacy = values.get(key);
        if (legacy != null) {
          values.put(scopedKey, legacy);
          values.remove(key);
          existing = legacy;
        }
      }
      if (existing != null) {
        return (T) existing;
      }
      CacheBuilder builder = instantiateBuilder(builderType);
      Object loaded = builder == null ? null : builder.doLoad(key);
      if (loaded != null) {
        values.put(scopedKey, loaded);
      }
      return (T) loaded;
    }

    public <T> T get(System.Type builderType, String key) {
      return get(resolveBuilderType(builderType), key);
    }

    public void put(String key, Object value) {
      values.put(key, value);
    }

    public void put(String key, Object value, Integer ttlSeconds) {
      values.put(key, value);
    }

    public boolean contains(String key) {
      return values.containsKey(key);
    }

    public List<String> getKeys() {
      return new ArrayList<>(values.keySet());
    }

    public Integer getNumKeys() {
      return values.size();
    }

    public void remove(String key) {
      values.remove(key);
    }

    public void remove(Class<? extends CacheBuilder> builderType, String key) {
      if (builderType == null) {
        remove(key);
        return;
      }
      values.remove(builderScopedKey(builderType, key));
      if (key != null) {
        values.remove(key);
      }
    }

    public void remove(System.Type builderType, String key) {
      remove(resolveBuilderType(builderType), key);
    }

    private static CacheBuilder instantiateBuilder(Class<? extends CacheBuilder> builderType) {
      try {
        var ctor = builderType.getDeclaredConstructor();
        ctor.setAccessible(true);
        return ctor.newInstance();
      } catch (InstantiationException
          | IllegalAccessException
          | InvocationTargetException
          | NoSuchMethodException ex) {
        throw new RuntimeException("failed to instantiate cache builder: " + builderType.getName(), ex);
      }
    }

    @SuppressWarnings("unchecked")
    private static Class<? extends CacheBuilder> resolveBuilderType(System.Type type) {
      if (type != null) {
        try {
          Object instance = type.newInstance();
          if (instance != null) {
            if (!CacheBuilder.class.isAssignableFrom(instance.getClass())) {
              throw new IllegalArgumentException(
                  "cache builder type must implement Cache.CacheBuilder: "
                      + instance.getClass().getName());
            }
            return (Class<? extends CacheBuilder>) instance.getClass();
          }
        } catch (RuntimeException ignored) {
          // Fall through to class-name resolution.
        }
      }

      Class<?> resolved = resolveTypeClass(type);
      if (resolved == null) {
        return null;
      }
      if (!CacheBuilder.class.isAssignableFrom(resolved)) {
        throw new IllegalArgumentException(
          "cache builder type must implement Cache.CacheBuilder: " + resolved.getName());
      }
      return (Class<? extends CacheBuilder>) resolved;
    }

    private static String builderScopedKey(Class<? extends CacheBuilder> builderType, String key) {
      String builderName = builderType == null ? "<builder>" : builderType.getName();
      String normalizedKey = key == null ? "<null>" : key;
      return builderName + "::" + normalizedKey;
    }

    private static Class<?> resolveTypeClass(System.Type type) {
      if (type == null || type.getName() == null || type.getName().isBlank()) {
        return null;
      }
      String normalized = type.getName().trim();
      String[] candidates = {
        normalized,
        normalized.replace('.', '$'),
        "generated." + normalized,
        "generated." + normalized.replace('.', '$'),
        "apexemu.runtime." + normalized,
        "apexemu.runtime." + normalized.replace('.', '$')
      };
      ClassLoader cl = Thread.currentThread().getContextClassLoader();
      if (cl == null) {
        cl = Cache.class.getClassLoader();
      }
      for (String candidate : candidates) {
        try {
          return Class.forName(candidate, true, cl);
        } catch (ClassNotFoundException ignored) {
          // try next candidate
        }
      }
      return null;
    }
  }

  public static final class OrgPartition extends Partition {
    public Integer getCapacity() {
      return values.size();
    }
  }

  public static final class SessionPartition extends Partition {}

  public static final class Org {
    private Org() {}

    public static OrgPartition getPartition(String name) {
      String key = normalizePartitionName(name);
      return ORG_PARTITIONS.computeIfAbsent(key, ignored -> new OrgPartition());
    }
  }

  public static final class Session {
    private Session() {}

    public static SessionPartition getPartition(String name) {
      String key = normalizePartitionName(name);
      return SESSION_PARTITIONS.computeIfAbsent(key, ignored -> new SessionPartition());
    }
  }

  private static String normalizePartitionName(String name) {
    if (name == null || name.isBlank()) {
      return "default";
    }
    return name.trim();
  }
}
