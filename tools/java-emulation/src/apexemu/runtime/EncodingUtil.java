package apexemu.runtime;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

public final class EncodingUtil {
  private EncodingUtil() {}

  public static byte[] base64Decode(String value) {
    if (value == null || value.isBlank()) {
      return new byte[0];
    }
    try {
      return Base64.getDecoder().decode(value);
    } catch (IllegalArgumentException ignored) {
      return value.getBytes(StandardCharsets.UTF_8);
    }
  }
}
