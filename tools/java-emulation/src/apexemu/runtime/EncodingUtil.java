package apexemu.runtime;

import java.nio.charset.StandardCharsets;
import java.net.URLEncoder;
import java.util.Base64;

public final class EncodingUtil {
  private EncodingUtil() {}

  public static byte[] base64Decode(String value) {
    if (value == null || value.isBlank()) {
      return new byte[0];
    }
    // Strip whitespace and literal "\n" (backslash-n) sequences that may appear
    // in transpiled Apex string literals
    String cleaned = value.replaceAll("\\\\n", "").replaceAll("\\s", "");
    try {
      return Base64.getDecoder().decode(cleaned);
    } catch (IllegalArgumentException ignored) {
      // Try MIME decoder as fallback (handles padding issues)
      try {
        return Base64.getMimeDecoder().decode(value);
      } catch (IllegalArgumentException ignored2) {
        return value.getBytes(StandardCharsets.UTF_8);
      }
    }
  }

  public static String base64Encode(byte[] value) {
    if (value == null || value.length == 0) {
      return "";
    }
    return Base64.getEncoder().encodeToString(value);
  }

  public static String urlEncode(String value, String charsetName) {
    if (value == null) {
      return "";
    }
    try {
      if (charsetName == null || charsetName.isBlank()) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
      }
      return URLEncoder.encode(value, java.nio.charset.Charset.forName(charsetName.trim()));
    } catch (Exception ignored) {
      return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
  }

  public static String convertToHex(byte[] value) {
    if (value == null || value.length == 0) {
      return "";
    }
    StringBuilder out = new StringBuilder(value.length * 2);
    for (byte b : value) {
      out.append(String.format("%02x", b));
    }
    return out.toString();
  }

  public static String ConvertToHex(byte[] value) {
    return convertToHex(value);
  }

  public static String ConvertTohex(byte[] value) {
    return convertToHex(value);
  }

  public static byte[] convertFromHex(String value) {
    if (value == null || value.isBlank()) {
      return new byte[0];
    }
    String hex = value.trim();
    if ((hex.length() & 1) == 1) {
      hex = "0" + hex;
    }
    byte[] out = new byte[hex.length() / 2];
    for (int i = 0; i < hex.length(); i += 2) {
      try {
        out[i / 2] = (byte) Integer.parseInt(hex.substring(i, i + 2), 16);
      } catch (NumberFormatException ignored) {
        return new byte[0];
      }
    }
    return out;
  }
}
