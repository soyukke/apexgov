package apexemu.runtime;

public final class Request {
  private static final Request CURRENT = new Request();

  private Request() {}

  public static Request getCurrent() {
    return CURRENT;
  }

  public static String getRequestId() {
    return System.Request.getCurrent().getRequestId();
  }

  public static System.Quiddity getQuiddity() {
    return System.Request.getCurrent().getQuiddity();
  }
}
