package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public final class HttpResponse {
  private int statusCode = 200;
  private String status = "OK";
  private String body = "";
  private final Map<String, String> headers = new LinkedHashMap<>();

  public Integer getStatusCode() {
    return statusCode;
  }

  public void setStatusCode(Integer statusCode) {
    if (statusCode == null) {
      this.statusCode = 0;
      return;
    }
    this.statusCode = statusCode;
  }

  public String getStatus() {
    return status;
  }

  public void setStatus(String status) {
    this.status = status == null ? "" : status;
  }

  public String getBody() {
    return body;
  }

  public void setBody(String body) {
    this.body = body == null ? "" : body;
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
}
