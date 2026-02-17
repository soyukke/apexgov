package apexemu.runtime;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class Test {
  private static final ThreadLocal<Map<Class<?>, Object>> MOCKS =
      ThreadLocal.withInitial(HashMap::new);

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

  public static void setCurrentPage(PageReference pageReference) {
    ApexPages.setCurrentPage(pageReference);
  }

  public static void runAs(ApexSObject user, Runnable work) {
    if (user == null) {
      throw new IllegalArgumentException("runAs user cannot be null");
    }
    if (work == null) {
      throw new IllegalArgumentException("runAs work cannot be null");
    }
    String userId = user.id();
    if (userId == null || userId.isBlank()) {
      throw new IllegalArgumentException("runAs user must have Id");
    }
    UserContext.runAs(userId, () -> Schema.runAs(user, work));
  }

  public static List<ApexSObject> loadData(String sobjectType, String csvPath) {
    return TestData.loadData(sobjectType, csvPath);
  }

  public static <T> void setMock(Class<T> mockType, T mockImpl) {
    if (mockType == null) {
      throw new IllegalArgumentException("mockType cannot be null");
    }
    if (mockImpl == null) {
      throw new IllegalArgumentException("mock implementation cannot be null");
    }
    if (!mockType.isInstance(mockImpl)) {
      throw new IllegalArgumentException(
          "mock implementation type mismatch: expected " + mockType.getSimpleName());
    }
    MOCKS.get().put(mockType, mockImpl);
  }

  public static void clearMocks() {
    MOCKS.get().clear();
  }

  static <T> T getMock(Class<T> mockType) {
    if (mockType == null) {
      return null;
    }
    Object value = MOCKS.get().get(mockType);
    if (value == null) {
      return null;
    }
    return mockType.cast(value);
  }
}
