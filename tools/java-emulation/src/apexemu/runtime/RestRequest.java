package apexemu.runtime;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

public class RestRequest {
  public String requestURI = "";
  public String httpMethod = "GET";
  public Object requestBody = "";
  public Map<String, String> headers = new LinkedHashMap<>();
  public Map<String, String> params = new LinkedHashMap<>();

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

  public void addParameter(String name, String value) {
    if (name == null || name.isBlank()) {
      return;
    }
    params.put(name, value);
  }

  public byte[] getBody() {
    if (requestBody == null) {
      return null;
    }
    if (requestBody instanceof byte[] bytes) {
      return bytes;
    }
    return String.valueOf(requestBody).getBytes(StandardCharsets.UTF_8);
  }

  public void setBody(Object body) {
    this.requestBody = body;
  }
}
