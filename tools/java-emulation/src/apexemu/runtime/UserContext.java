package apexemu.runtime;

final class UserContext {
  private static final String DEFAULT_USER_ID = "005000000000001";
  private static final ThreadLocal<String> CURRENT_USER_ID =
      ThreadLocal.withInitial(() -> DEFAULT_USER_ID);
  private static final ThreadLocal<ApexSObject> CURRENT_USER =
      ThreadLocal.withInitial(
          () -> ApexSObject.of("User").withId(DEFAULT_USER_ID).set("Username", "user@example.test"));

  private UserContext() {}

  static String currentUserId() {
    String userId = CURRENT_USER_ID.get();
    if (userId == null || userId.isBlank()) {
      return DEFAULT_USER_ID;
    }
    return userId;
  }

  static void setCurrentUserId(String userId) {
    String normalized = normalizeUserId(userId);
    CURRENT_USER_ID.set(normalized);
    ApexSObject currentUser = CURRENT_USER.get();
    if (currentUser == null) {
      CURRENT_USER.set(ApexSObject.of("User").withId(normalized));
    } else {
      currentUser.withId(normalized);
    }
  }

  static ApexSObject currentUser() {
    ApexSObject user = CURRENT_USER.get();
    if (user == null) {
      user = ApexSObject.of("User").withId(currentUserId());
      CURRENT_USER.set(user);
    }
    return user;
  }

  static void setCurrentUser(ApexSObject user) {
    if (user == null) {
      CURRENT_USER.set(ApexSObject.of("User").withId(DEFAULT_USER_ID).set("Username", "user@example.test"));
      CURRENT_USER_ID.set(DEFAULT_USER_ID);
      return;
    }
    String normalized = normalizeUserId(user.id());
    user.withId(normalized);
    CURRENT_USER.set(user);
    CURRENT_USER_ID.set(normalized);
  }

  static String currentUsername() {
    ApexSObject user = currentUser();
    if (user != null) {
      Object rawUsername = user.get("Username");
      if (rawUsername != null) {
        String username = String.valueOf(rawUsername).trim();
        if (!username.isEmpty()) {
          return username;
        }
      }
      Object rawEmail = user.get("Email");
      if (rawEmail != null) {
        String email = String.valueOf(rawEmail).trim();
        if (!email.isEmpty()) {
          return email;
        }
      }
    }
    String userId = currentUserId();
    if (userId == null || userId.isBlank()) {
      return "user@example.test";
    }
    return userId + "@example.test";
  }

  static void runAs(String userId, Runnable work) {
    runAs(userId, null, work);
  }

  static void runAs(String userId, ApexSObject user, Runnable work) {
    if (work == null) {
      throw new IllegalArgumentException("runAs work cannot be null");
    }
    String normalized = normalizeUserId(userId);
    String previous = CURRENT_USER_ID.get();
    ApexSObject previousUser = CURRENT_USER.get();
    CURRENT_USER_ID.set(normalized);
    if (user != null) {
      user.withId(normalized);
      CURRENT_USER.set(user);
    } else if (previousUser != null) {
      ApexSObject inherited = previousUser.copy();
      inherited.withId(normalized);
      CURRENT_USER.set(inherited);
    } else {
      CURRENT_USER.set(ApexSObject.of("User").withId(normalized));
    }
    try {
      work.run();
    } finally {
      CURRENT_USER_ID.set(previous);
      CURRENT_USER.set(previousUser);
    }
  }

  private static String normalizeUserId(String userId) {
    if (userId == null || userId.isBlank()) {
      return DEFAULT_USER_ID;
    }
    return userId.trim();
  }
}
