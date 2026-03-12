package apexemu.runtime;

import java.math.BigDecimal;
import java.math.RoundingMode;

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

  public static Double setScale(Number value, int scale) {
    if (value == null) {
      return null;
    }
    return BigDecimal.valueOf(value.doubleValue()).setScale(scale, RoundingMode.HALF_UP).doubleValue();
  }

  public static Double setScale(Number value, int scale, java.math.RoundingMode roundingMode) {
    if (value == null) {
      return null;
    }
    java.math.RoundingMode mode = roundingMode == null ? java.math.RoundingMode.HALF_UP : roundingMode;
    return BigDecimal.valueOf(value.doubleValue()).setScale(scale, mode).doubleValue();
  }

  public static Double setScale(Number value, int scale, apexemu.runtime.System.RoundingMode roundingMode) {
    java.math.RoundingMode mode = roundingMode == null ? java.math.RoundingMode.HALF_UP : roundingMode.toJavaMode();
    return setScale(value, scale, mode);
  }

  public static Double divide(Number left, Number right, int scale, java.math.RoundingMode roundingMode) {
    if (left == null || right == null) {
      return null;
    }
    if (right.doubleValue() == 0.0d) {
      return null;
    }
    java.math.RoundingMode mode = roundingMode == null ? java.math.RoundingMode.HALF_UP : roundingMode;
    BigDecimal dividend = BigDecimal.valueOf(left.doubleValue());
    BigDecimal divisor = BigDecimal.valueOf(right.doubleValue());
    return dividend.divide(divisor, scale, mode).doubleValue();
  }

  public static Double divide(Number left, Number right, int scale, apexemu.runtime.System.RoundingMode roundingMode) {
    java.math.RoundingMode mode = roundingMode == null ? java.math.RoundingMode.HALF_UP : roundingMode.toJavaMode();
    return divide(left, right, scale, mode);
  }
}
