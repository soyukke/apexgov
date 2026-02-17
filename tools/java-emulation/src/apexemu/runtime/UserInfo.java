package apexemu.runtime;

public final class UserInfo {
  private UserInfo() {}

  public static String getUserId() {
    return UserContext.currentUserId();
  }
}
