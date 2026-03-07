package apexemu.runtime;

public final class Id {
  private Id() {}

  public static boolean isValid(Object value) {
    if (value == null) {
      return false;
    }
    String text = String.valueOf(value).trim();
    if (text.isEmpty()) {
      return false;
    }
    int len = text.length();
    if (len != 15 && len != 18) {
      return false;
    }
    for (int i = 0; i < len; i++) {
      char c = text.charAt(i);
      if (!(c >= '0' && c <= '9') && !(c >= 'A' && c <= 'Z') && !(c >= 'a' && c <= 'z')) {
        return false;
      }
    }
    return true;
  }

  public static String valueOf(Object value) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value).trim();
    if (text.isEmpty()) {
      return text;
    }
    if (text.length() == 15) {
      return text + "AAA";
    }
    return text;
  }
}
