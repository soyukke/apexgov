package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public final class HttpRequest {
  private String endpoint;
  private String method = "GET";
  private String body;
  private final Map<String, String> headers = new LinkedHashMap<>();
  private int timeout = 10000;

  public String getEndpoint() {
    return endpoint;
  }

  public String getEndPoint() {
    return getEndpoint();
  }

  public void setEndpoint(String endpoint) {
    this.endpoint = endpoint;
  }

  public String getMethod() {
    return method;
  }

  public void setMethod(String method) {
    if (method == null || method.isBlank()) {
      this.method = "GET";
      return;
    }
    this.method = method.trim().toUpperCase();
  }

  public String getBody() {
    return body;
  }

  public void setBody(String body) {
    this.body = body;
  }

  public void setHeader(String name, String value) {
    if (name == null || name.isBlank()) {
      throw new IllegalArgumentException("header name cannot be blank");
    }
    headers.put(name.trim(), value == null ? "" : value);
  }

  public String getHeader(String name) {
    if (name == null || name.isBlank()) {
      return null;
    }
    for (Map.Entry<String, String> entry : headers.entrySet()) {
      if (entry.getKey().equalsIgnoreCase(name)) {
        return entry.getValue();
      }
    }
    return null;
  }

  public Map<String, String> getHeaders() {
    return Map.copyOf(headers);
  }

  public void setTimeout(int timeout) {
    this.timeout = Math.max(0, timeout);
  }

  public int getTimeout() {
    return timeout;
  }
}
