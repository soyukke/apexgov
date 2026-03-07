package apexemu.runtime;

public final class RestContext {
  private RestContext() {}

  public static RestRequest request = new RestRequest();
  public static RestResponse response = new RestResponse();

  public static void reset() {
    request = new RestRequest();
    response = new RestResponse();
  }
}
