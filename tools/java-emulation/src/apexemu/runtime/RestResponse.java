package apexemu.runtime;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

public class RestResponse {
  public Integer statusCode = 200;
  public Object responseBody = "";
  public Map<String, String> headers = new LinkedHashMap<>();

  public void addHeader(String name, String value) {
    if (name == null || name.isBlank()) {
      return;
    }
    headers.put(name, value);
  }

  public String getHeader(String name) {
    if (name == null || name.isBlank()) {
      return null;
    }
    return headers.get(name);
  }

  public void setBody(Object body) {
    this.responseBody = body;
  }

  public byte[] getBody() {
    if (responseBody == null) {
      return null;
    }
    if (responseBody instanceof byte[] bytes) {
      return bytes;
    }
    return String.valueOf(responseBody).getBytes(StandardCharsets.UTF_8);
  }
}
