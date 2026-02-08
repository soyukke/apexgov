package apexemu.runtime;

public final class Test {
  private Test() {}

  public static void startTest() {
    Async.startTestWindow();
    Limits.startTest();
  }

  public static void stopTest() {
    Async.flush();
    Limits.stopTest();
  }

  public static String enqueueFuture(Runnable task) {
    return Async.enqueueFuture(task);
  }

  public static String enqueueFutureMethod(Class<?> owner, String methodName) {
    return Async.enqueueFutureMethod(owner, methodName);
  }

  public static Async.Snapshot getAsyncSnapshot() {
    return Async.snapshot();
  }

  public static boolean isRunningTest() {
    return true;
  }
}
