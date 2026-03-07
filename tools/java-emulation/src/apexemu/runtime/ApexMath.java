package apexemu.runtime;

public final class ApexMath {
  private ApexMath() {}

  public static int mod(int value, int divisor) {
    if (divisor == 0) return 0;
    return value % divisor;
  }

  public static Integer mod(Integer value, int divisor) {
    if (value == null) return null;
    if (divisor == 0) return 0;
    return value % divisor;
  }

  public static Integer mod(int value, Integer divisor) {
    if (divisor == null) return null;
    if (divisor == 0) return 0;
    return value % divisor;
  }

  public static long mod(long value, long divisor) {
    if (divisor == 0L) return 0L;
    return value % divisor;
  }

  public static Long mod(Long value, long divisor) {
    if (value == null) return null;
    if (divisor == 0L) return 0L;
    return value % divisor;
  }

  public static Long mod(long value, Long divisor) {
    if (divisor == null) return null;
    if (divisor == 0L) return 0L;
    return value % divisor;
  }

  public static Integer mod(Integer value, Integer divisor) {
    if (value == null || divisor == null) return null;
    if (divisor == 0) return 0;
    return value % divisor;
  }

  public static Long mod(Long value, Long divisor) {
    if (value == null || divisor == null) return null;
    if (divisor == 0L) return 0L;
    return value % divisor;
  }
}
