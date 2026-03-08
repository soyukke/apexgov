package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public final class Auth {
  private Auth() {}

  public static class JWT {
    private final Map<String, Object> claims = new LinkedHashMap<>();

    public JWT set(String key, Object value) {
      if (key != null && !key.isBlank()) {
        claims.put(key, value);
      }
      return this;
    }

    public String toJSONString() {
      return JSON.serialize(claims);
    }
  }
}
