package apexemu.runtime;

import java.nio.charset.StandardCharsets;

public final class Blob {
  private Blob() {}

  public static byte[] valueOf(String value) {
    if (value == null) {
      return new byte[0];
    }
    return value.getBytes(StandardCharsets.UTF_8);
  }

  /** Convert byte[] to String using UTF-8 (Apex Blob.toString() semantics). */
  public static String blobToString(byte[] data) {
    if (data == null) {
      return null;
    }
    return new String(data, StandardCharsets.UTF_8);
  }
}
