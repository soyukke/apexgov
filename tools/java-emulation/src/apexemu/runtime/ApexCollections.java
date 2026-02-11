package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class ApexCollections {
  private ApexCollections() {}

  public static Map<String, ApexSObject> mapById(List<ApexSObject> rows) {
    Map<String, ApexSObject> out = new LinkedHashMap<>();
    if (rows == null || rows.isEmpty()) {
      return out;
    }
    for (ApexSObject row : rows) {
      if (row == null) {
        continue;
      }
      String id = row.id();
      if (id == null) {
        Object fromField = row.get("Id");
        if (fromField instanceof String s && !s.isBlank()) {
          id = s;
        } else if (fromField != null) {
          id = String.valueOf(fromField);
        }
      }
      if (id == null || id.isBlank()) {
        continue;
      }
      out.put(id, row);
    }
    return out;
  }

  public static ApexSObject firstOrNull(List<ApexSObject> rows) {
    if (rows == null || rows.isEmpty()) {
      return null;
    }
    return rows.get(0);
  }
}
