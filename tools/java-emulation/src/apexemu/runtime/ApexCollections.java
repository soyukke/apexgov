package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

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
