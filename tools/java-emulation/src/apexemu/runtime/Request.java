package apexemu.runtime;

public final class Request {
  private Request() {}

  public static System.Request getCurrent() {
    return System.Request.getCurrent();
  }

  public static String getRequestId() {
    return getCurrent().getRequestId();
  }
}
