package apexemu.runtime;

final class UserContext {
  private static final String DEFAULT_USER_ID = "005000000000001";
  private static final ThreadLocal<String> CURRENT_USER_ID =
      ThreadLocal.withInitial(() -> DEFAULT_USER_ID);

  private UserContext() {}

  static String currentUserId() {
    String userId = CURRENT_USER_ID.get();
    if (userId == null || userId.isBlank()) {
      return DEFAULT_USER_ID;
    }
    return userId;
  }

  static void runAs(String userId, Runnable work) {
    if (work == null) {
      throw new IllegalArgumentException("runAs work cannot be null");
    }
    String normalized = normalizeUserId(userId);
    String previous = CURRENT_USER_ID.get();
    CURRENT_USER_ID.set(normalized);
    try {
      work.run();
    } finally {
      CURRENT_USER_ID.set(previous);
    }
  }

  private static String normalizeUserId(String userId) {
    if (userId == null || userId.isBlank()) {
      throw new IllegalArgumentException("userId cannot be blank");
    }
    return userId.trim();
  }
}
