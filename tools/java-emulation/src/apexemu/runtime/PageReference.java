package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public final class PageReference {
  private final String url;
  private final Map<String, String> parameters = new LinkedHashMap<>();
  private boolean redirect;

  public PageReference(String url) {
    this.url = url == null ? "" : url;
  }

  public String getUrl() {
    return url;
  }

  public String getURL() {
    return getUrl();
  }

  public Map<String, String> getParameters() {
    return parameters;
  }

  public void setRedirect(boolean redirect) {
    this.redirect = redirect;
  }

  public boolean getRedirect() {
    return redirect;
  }

  public boolean isRedirect() {
    return redirect;
  }
}
