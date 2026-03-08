package apexemu.runtime;

import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public final class Crypto {
  private static final SecureRandom RANDOM = new SecureRandom();

  private Crypto() {}

  public static byte[] generateAESKey(int bits) {
    int size = Math.max(16, bits / 8);
    byte[] out = new byte[size];
    RANDOM.nextBytes(out);
    return out;
  }

  public static byte[] generateAesKey(int bits) {
    return generateAESKey(bits);
  }

  public static Integer getRandomInteger() {
    return RANDOM.nextInt(Integer.MAX_VALUE);
  }

  public static Long getRandomLong() {
    return RANDOM.nextLong();
  }

  public static byte[] encryptWithManagedIV(String algorithm, byte[] key, byte[] data) {
    try {
      String jceAlgorithm = toCipherAlgorithm(algorithm);
      byte[] iv = new byte[16];
      RANDOM.nextBytes(iv);
      Cipher cipher = Cipher.getInstance(jceAlgorithm);
      cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(iv));
      byte[] encrypted = cipher.doFinal(data == null ? new byte[0] : data);
      byte[] out = new byte[iv.length + encrypted.length];
      java.lang.System.arraycopy(iv, 0, out, 0, iv.length);
      java.lang.System.arraycopy(encrypted, 0, out, iv.length, encrypted.length);
      return out;
    } catch (Exception error) {
      throw new RuntimeException("encryptWithManagedIV failed: " + error.getMessage(), error);
    }
  }

  public static byte[] decryptWithManagedIV(String algorithm, byte[] key, byte[] data) {
    try {
      if (data == null || data.length <= 16) {
        return new byte[0];
      }
      String jceAlgorithm = toCipherAlgorithm(algorithm);
      byte[] iv = Arrays.copyOfRange(data, 0, 16);
      byte[] ciphertext = Arrays.copyOfRange(data, 16, data.length);
      Cipher cipher = Cipher.getInstance(jceAlgorithm);
      cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(iv));
      return cipher.doFinal(ciphertext);
    } catch (Exception error) {
      throw new RuntimeException("decryptWithManagedIV failed: " + error.getMessage(), error);
    }
  }

  public static byte[] encrypt(String algorithm, byte[] key, byte[] iv, byte[] data) {
    try {
      String jceAlgorithm = toCipherAlgorithm(algorithm);
      Cipher cipher = Cipher.getInstance(jceAlgorithm);
      cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(iv));
      return cipher.doFinal(data == null ? new byte[0] : data);
    } catch (Exception error) {
      throw new RuntimeException("encrypt failed: " + error.getMessage(), error);
    }
  }

  public static byte[] decrypt(String algorithm, byte[] key, byte[] iv, byte[] data) {
    try {
      String jceAlgorithm = toCipherAlgorithm(algorithm);
      Cipher cipher = Cipher.getInstance(jceAlgorithm);
      cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(iv));
      return cipher.doFinal(data == null ? new byte[0] : data);
    } catch (Exception error) {
      throw new RuntimeException("decrypt failed: " + error.getMessage(), error);
    }
  }

  public static byte[] generateDigest(String algorithm, byte[] data) {
    String name = normalizeDigestAlgorithm(algorithm);
    try {
      MessageDigest digest = MessageDigest.getInstance(name);
      return digest.digest(data == null ? new byte[0] : data);
    } catch (Exception ignored) {
      return new byte[0];
    }
  }

  public static byte[] generateMac(String algorithm, byte[] data, byte[] key) {
    String name = normalizeMacAlgorithm(algorithm);
    try {
      Mac mac = Mac.getInstance(name);
      byte[] normalizedKey = key == null || key.length == 0 ? new byte[] {0} : key;
      mac.init(new SecretKeySpec(normalizedKey, name));
      return mac.doFinal(data == null ? new byte[0] : data);
    } catch (Exception ignored) {
      return new byte[0];
    }
  }

  public static boolean verifyHMAC(String algorithm, byte[] data, byte[] key, byte[] hmac) {
    return Arrays.equals(generateMac(algorithm, data, key), hmac == null ? new byte[0] : hmac);
  }

  public static byte[] sign(String algorithm, byte[] data, byte[] privateKey) {
    String sigAlgorithm = normalizeSignatureAlgorithm(algorithm);
    if (sigAlgorithm != null && privateKey != null && privateKey.length > 0) {
      try {
        PKCS8EncodedKeySpec keySpec = new PKCS8EncodedKeySpec(privateKey);
        KeyFactory keyFactory = KeyFactory.getInstance("RSA");
        PrivateKey rsaKey = keyFactory.generatePrivate(keySpec);
        Signature sig = Signature.getInstance(sigAlgorithm);
        sig.initSign(rsaKey);
        sig.update(data == null ? new byte[0] : data);
        return sig.sign();
      } catch (Exception e) {
        // fall through to HMAC-based signing
      }
    }
    return generateMac(algorithm, data, privateKey);
  }

  public static boolean verify(String algorithm, byte[] data, byte[] signature, byte[] publicKey) {
    String sigAlgorithm = normalizeSignatureAlgorithm(algorithm);
    if (sigAlgorithm != null) {
      try {
        java.security.spec.X509EncodedKeySpec keySpec = new java.security.spec.X509EncodedKeySpec(publicKey);
        java.security.KeyFactory keyFactory = java.security.KeyFactory.getInstance("RSA");
        java.security.PublicKey rsaPubKey = keyFactory.generatePublic(keySpec);
        Signature sig = Signature.getInstance(sigAlgorithm);
        sig.initVerify(rsaPubKey);
        sig.update(data == null ? new byte[0] : data);
        return sig.verify(signature == null ? new byte[0] : signature);
      } catch (Exception e) {
        // fall through to HMAC-based verification
      }
    }
    return Arrays.equals(generateMac(algorithm, data, publicKey), signature == null ? new byte[0] : signature);
  }

  private static String toCipherAlgorithm(String algorithm) {
    if (algorithm == null || algorithm.isBlank()) {
      return "AES/CBC/PKCS5Padding";
    }
    String normalized = algorithm.trim().toUpperCase().replace("_", "");
    if (normalized.contains("AES") && normalized.contains("256")) {
      return "AES/CBC/PKCS5Padding";
    }
    if (normalized.contains("AES") && normalized.contains("128")) {
      return "AES/CBC/PKCS5Padding";
    }
    if (normalized.contains("AES")) {
      return "AES/CBC/PKCS5Padding";
    }
    return "AES/CBC/PKCS5Padding";
  }

  private static String normalizeDigestAlgorithm(String algorithm) {
    if (algorithm == null || algorithm.isBlank()) {
      return "SHA-256";
    }
    String normalized = algorithm.trim().replace("_", "-").toUpperCase();
    if (normalized.startsWith("SHA")) {
      return normalized;
    }
    if (normalized.equals("MD5")) {
      return "MD5";
    }
    return "SHA-256";
  }

  private static String normalizeMacAlgorithm(String algorithm) {
    if (algorithm == null || algorithm.isBlank()) {
      return "HmacSHA256";
    }
    String normalized = algorithm.trim().replace("_", "").toUpperCase();
    if (normalized.startsWith("HMACSHA")) {
      String suffix = normalized.substring("HMACSHA".length());
      return "HmacSHA" + suffix;
    }
    return "HmacSHA256";
  }

  private static String normalizeSignatureAlgorithm(String algorithm) {
    if (algorithm == null || algorithm.isBlank()) {
      return null;
    }
    String normalized = algorithm.trim().toUpperCase().replace("_", "").replace("-", "");
    if (normalized.contains("RSA") && normalized.contains("SHA256")) {
      return "SHA256withRSA";
    }
    if (normalized.contains("RSA") && normalized.contains("SHA1")) {
      return "SHA1withRSA";
    }
    if (normalized.contains("RSA") && normalized.contains("SHA512")) {
      return "SHA512withRSA";
    }
    if (normalized.contains("RSA")) {
      return "SHA256withRSA";
    }
    return null;
  }
}
