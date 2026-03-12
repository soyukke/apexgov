package apexemu.runtime;

public final class Site {
  private Site() {}

  public static String getBaseUrl() {
    return URL.getOrgDomainUrl().toExternalForm();
  }
}
