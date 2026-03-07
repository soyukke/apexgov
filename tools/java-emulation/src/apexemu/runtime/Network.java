package apexemu.runtime;

public final class Network {
  private Network() {}

  public static PageReference communitiesLanding() {
    if (Test.isRunningTest()) {
      return new PageReference("");
    }
    return new PageReference("/");
  }
}
