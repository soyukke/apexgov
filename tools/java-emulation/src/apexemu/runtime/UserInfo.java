package apexemu.runtime;

public final class UserInfo {
  private UserInfo() {}

  public static String getUserId() {
    return UserContext.currentUserId();
  }

  public static String getUsername() {
    return UserContext.currentUsername();
  }

  // Apex API aliases (`UserInfo.getUserName()`).
  public static String getUserName() {
    return getUsername();
  }

  public static String getProfileId() {
    String profileId = Schema.getCurrentProfileId();
    if (profileId != null && !profileId.isBlank()) {
      return profileId;
    }
    ApexSObject user = UserContext.currentUser();
    if (user != null) {
      Object raw = user.get("ProfileId");
      if (raw == null) {
        raw = user.get("profileId");
      }
      if (raw != null) {
        String value = String.valueOf(raw).trim();
        if (!value.isEmpty()) {
          return value;
        }
      }
    }
    return null;
  }

  public static String getEmail() {
    ApexSObject user = UserContext.currentUser();
    if (user != null) {
      Object raw = user.get("Email");
      if (raw == null) {
        raw = user.get("email");
      }
      if (raw != null) {
        String value = String.valueOf(raw).trim();
        if (!value.isEmpty()) {
          return value;
        }
      }
    }
    return getUsername();
  }

  public static String getName() {
    ApexSObject user = UserContext.currentUser();
    if (user != null) {
      Object raw = user.get("Name");
      if (raw != null) {
        String value = String.valueOf(raw).trim();
        if (!value.isEmpty()) {
          return value;
        }
      }
      Object first = user.get("FirstName");
      Object last = user.get("LastName");
      String text = ((first == null ? "" : String.valueOf(first).trim()) + " "
              + (last == null ? "" : String.valueOf(last).trim()))
          .trim();
      if (!text.isEmpty()) {
        return text;
      }
    }
    return getUsername();
  }

  public static String getOrganizationId() {
    return "00D000000000001";
  }

  public static boolean isMultiCurrencyOrganization() {
    return false;
  }

  public static String getUiThemeDisplayed() {
    return "Theme4d";
  }
}
