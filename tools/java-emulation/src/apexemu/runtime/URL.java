package apexemu.runtime;

public final class URL {
  private final String externalForm;

  private URL(String externalForm) {
    this.externalForm = externalForm == null ? "http://localhost" : externalForm;
  }

  public static URL getOrgDomainUrl() {
    return new URL("http://localhost");
  }

  public static URL getSalesforceBaseUrl() {
    return getOrgDomainUrl();
  }

  public String toExternalForm() {
    return externalForm;
  }

  public String getHost() {
    try {
      java.net.URI uri = java.net.URI.create(externalForm);
      if (uri.getHost() != null) {
        return uri.getHost();
      }
    } catch (IllegalArgumentException ignored) {
    }
    return "localhost";
  }

  @Override
  public String toString() {
    return externalForm;
  }
}
