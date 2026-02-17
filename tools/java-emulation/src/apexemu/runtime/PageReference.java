package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public final class PageReference {
  private final String url;
  private final Map<String, String> parameters = new LinkedHashMap<>();

  public PageReference(String url) {
    this.url = url == null ? "" : url;
  }

  public String getUrl() {
    return url;
  }

  public Map<String, String> getParameters() {
    return parameters;
  }
}
