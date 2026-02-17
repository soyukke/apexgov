package apexemu.runtime;

import java.time.Instant;

public final class DateTime {
  private final Instant instant;

  private DateTime(Instant instant) {
    this.instant = instant == null ? Instant.EPOCH : instant;
  }

  public static DateTime now() {
    return new DateTime(Instant.now());
  }

  public long getTime() {
    return instant.toEpochMilli();
  }
}
