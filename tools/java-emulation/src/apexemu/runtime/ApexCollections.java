package apexemu.runtime;

import java.util.AbstractMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Set;

public final class ApexCollections {
  private ApexCollections() {}

  public static Map<String, ApexSObject> mapById(List<ApexSObject> rows) {
    return toIdMap(rows);
  }

  public static Map<String, ApexSObject> toIdMap(Object source) {
    Map<String, ApexSObject> out = new LinkedHashMap<>();
    if (source == null) {
      return out;
    }

    if (source instanceof Map<?, ?> sourceMap) {
      for (Map.Entry<?, ?> entry : sourceMap.entrySet()) {
        ApexSObject row = asSObject(entry.getValue());
        if (row == null) {
          continue;
        }
        String id = entry.getKey() == null ? null : String.valueOf(entry.getKey());
        if (id == null || id.isBlank()) {
          id = resolveId(row);
        }
        if (id == null || id.isBlank()) {
          continue;
        }
        out.put(id, row);
      }
      return out;
    }

    if (source instanceof Iterable<?> iterable) {
      for (Object item : iterable) {
        ApexSObject row = asSObject(item);
        if (row == null) {
          continue;
        }
        String id = resolveId(row);
        if (id == null || id.isBlank()) {
          continue;
        }
        out.put(id, row);
      }
      return out;
    }

    ApexSObject single = asSObject(source);
    if (single == null) {
      return out;
    }
    String id = resolveId(single);
    if (id == null || id.isBlank()) {
      return out;
    }
    out.put(id, single);
    return out;
  }

  public static ApexSObject firstOrNull(List<ApexSObject> rows) {
    if (rows == null || rows.isEmpty()) {
      return null;
    }
    return rows.get(0);
  }

  /** Like firstOrNull but throws QueryException when no rows found (Apex single-row assignment). */
  public static ApexSObject firstOrThrow(List<ApexSObject> rows) {
    if (rows == null || rows.isEmpty()) {
      throw new QueryException("List has no rows for assignment to SObject");
    }
    return rows.get(0);
  }

  public static <T> T firstOrNull(T value) {
    return value;
  }

  private static final ApexSObject EMPTY_SOBJECT = ApexSObject.of("__empty__");

  public static ApexSObject emptyIfNull(ApexSObject obj) {
    return obj != null ? obj : EMPTY_SOBJECT;
  }

  public static <T> List<T> listOf() {
    return new ArrayList<>();
  }

  public static <T> List<T> listOf(T first, T second) {
    List<T> list = new ArrayList<>(2);
    list.add(first);
    list.add(second);
    return list;
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  public static List listOf(Object first, Object second, Object third) {
    List list = new ArrayList(3);
    list.add(first);
    list.add(second);
    list.add(third);
    return list;
  }

  @SafeVarargs
  @SuppressWarnings("varargs")
  public static <T> List<T> listOf(T first, T... rest) {
    List<T> list = new ArrayList<>(1 + (rest == null ? 0 : rest.length));
    list.add(first);
    // listOf("x", null) is emitted by the transpiler and represents two elements in Apex.
    if (rest == null) {
      list.add(null);
      return list;
    }
    if (rest.length > 0) {
      java.util.Collections.addAll(list, rest);
    }
    return list;
  }

  /** Apex `new Type[n]` semantics: fixed-size list initialized with `n` null slots. */
  public static <T> List<T> newListWithSize(Object sizeValue) {
    if (sizeValue == null) {
      return new ArrayList<>();
    }
    Integer parsed = sizeValue instanceof Integer i ? i : ApexStrings.toInteger(sizeValue);
    int size = parsed == null ? 0 : Math.max(0, parsed);
    List<T> list = new ArrayList<>(size);
    for (int i = 0; i < size; i++) {
      list.add(null);
    }
    return list;
  }

  /** Backward compatibility for case-normalized transpiler output. */
  public static <T> List<T> newlistWithSize(Object sizeValue) {
    return newListWithSize(sizeValue);
  }

  public static <K, V> Map.Entry<K, V> mapEntry(K key, V value) {
    return new AbstractMap.SimpleImmutableEntry<>(key, value);
  }

  @SafeVarargs
  public static <K, V> Map<K, V> mapOfEntries(Map.Entry<? extends K, ? extends V>... entries) {
    Map<K, V> out = new LinkedHashMap<>();
    if (entries == null) {
      return out;
    }
    for (Map.Entry<? extends K, ? extends V> entry : entries) {
      if (entry == null) {
        continue;
      }
      out.put(entry.getKey(), entry.getValue());
    }
    return out;
  }

  public static Map<String, Object> bindMap(Object... keyValuePairs) {
    Map<String, Object> out = new LinkedHashMap<>();
    if (keyValuePairs == null || keyValuePairs.length == 0) {
      return out;
    }
    if (keyValuePairs.length % 2 != 0) {
      throw new IllegalArgumentException("bindMap requires an even number of key/value arguments");
    }
    for (int i = 0; i < keyValuePairs.length; i += 2) {
      Object keyRaw = keyValuePairs[i];
      if (keyRaw == null) {
        continue;
      }
      String key = String.valueOf(keyRaw);
      out.put(key, keyValuePairs[i + 1]);
    }
    return out;
  }

  public static <T> List<List<T>> chunk(List<T> rows, int chunkSize) {
    List<List<T>> out = new ArrayList<>();
    if (rows == null || rows.isEmpty()) {
      return out;
    }
    int normalized = Math.max(1, chunkSize);
    for (int offset = 0; offset < rows.size(); offset += normalized) {
      int end = Math.min(rows.size(), offset + normalized);
      out.add(new ArrayList<>(rows.subList(offset, end)));
    }
    return out;
  }

  public static <T> List<T> clone(List<T> values) {
    if (values == null) {
      return null;
    }
    return new ArrayList<>(values);
  }

  public static Integer size(Object value) {
    if (value == null) {
      return 0;
    }
    if (value instanceof Collection<?> collection) {
      return collection.size();
    }
    if (value instanceof Map<?, ?> map) {
      return map.size();
    }
    if (value.getClass().isArray()) {
      return java.lang.reflect.Array.getLength(value);
    }
    if (value instanceof CharSequence sequence) {
      return sequence.length();
    }
    return 0;
  }

  public static List<ApexSObject> deepClone(
      List<ApexSObject> values,
      Boolean preserveId,
      Boolean isDeepClone,
      Boolean preserveReadonlyTimestamps) {
    if (values == null) {
      return null;
    }
    List<ApexSObject> out = new ArrayList<>(values.size());
    for (ApexSObject value : values) {
      out.add(
          value == null
              ? null
              : value.clone(
                  Boolean.TRUE.equals(preserveId),
                  Boolean.TRUE.equals(isDeepClone),
                  Boolean.TRUE.equals(preserveReadonlyTimestamps),
                  false));
    }
    return out;
  }

  public static <T> Set<T> clone(Set<T> values) {
    if (values == null) {
      return null;
    }
    return new LinkedHashSet<>(values);
  }

  public static <K, V> Map<K, V> clone(Map<K, V> values) {
    if (values == null) {
      return null;
    }
    return new LinkedHashMap<>(values);
  }

  public static <T> T clone(T value) {
    if (value instanceof ApexSObject row) {
      @SuppressWarnings("unchecked")
      T cloned = (T) row.clone(false, true, false, false);
      return cloned;
    }
    return value;
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  public static void sort(List<?> rows) {
    if (rows == null || rows.size() < 2) {
      return;
    }
    List raw = (List) rows;
    raw.sort(
        new Comparator() {
          @Override
          public int compare(Object left, Object right) {
            if (left == right) {
              return 0;
            }
            if (left == null) {
              return -1;
            }
            if (right == null) {
              return 1;
            }
            if (left instanceof ApexComparable cmp) {
              Integer value = cmp.compareTo(right);
              return value == null ? 0 : value.intValue();
            }
            if (left instanceof Comparable cmp) {
              return cmp.compareTo(right);
            }
            return ApexStrings.compareTo(left, right);
          }
        });
  }

  private static ApexSObject asSObject(Object value) {
    if (value instanceof ApexSObject row) {
      return row;
    }
    return null;
  }

  private static String resolveId(ApexSObject row) {
    if (row == null) {
      return null;
    }
    String id = row.id();
    if (id != null && !id.isBlank()) {
      return id;
    }
    Object fromField = row.get("Id");
    if (fromField instanceof String s && !s.isBlank()) {
      return s;
    }
    if (fromField != null) {
      String asText = String.valueOf(fromField);
      if (!asText.isBlank()) {
        return asText;
      }
    }
    return null;
  }
}
