package apexemu.runtime;

import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Locale;
import java.util.Objects;

public final class DateTime {
  private final Instant instant;

  private DateTime(Instant instant) {
    this.instant = instant == null ? Instant.EPOCH : instant;
  }

  public static DateTime now() {
    return new DateTime(Instant.now());
  }

  public static DateTime newInstance(
      int year, int month, int day, int hour, int minute, int second) {
    ZonedDateTime local = ZonedDateTime.of(year, month, day, hour, minute, second, 0, ZoneOffset.UTC);
    return new DateTime(local.toInstant());
  }

  public static DateTime newInstanceGmt(
      int year, int month, int day, int hour, int minute, int second) {
    ZonedDateTime gmt = ZonedDateTime.of(year, month, day, hour, minute, second, 0, ZoneOffset.UTC);
    return new DateTime(gmt.toInstant());
  }

  public static DateTime fromDate(Date value) {
    if (value == null) {
      return null;
    }
    LocalDate date = value.value();
    return new DateTime(date.atStartOfDay(ZoneOffset.UTC).toInstant());
  }

  public long getTime() {
    return instant.toEpochMilli();
  }

  public DateTime addSeconds(int seconds) {
    return new DateTime(instant.plusSeconds(seconds));
  }

  public DateTime addDays(int days) {
    return new DateTime(instant.plusSeconds((long) days * 24L * 60L * 60L));
  }

  public String formatGMT(String pattern) {
    if (pattern == null || pattern.isBlank()) {
      return instant.toString();
    }
    try {
      DateTimeFormatter formatter = DateTimeFormatter.ofPattern(pattern, Locale.US);
      return formatter.format(ZonedDateTime.ofInstant(instant, ZoneOffset.UTC));
    } catch (IllegalArgumentException ignored) {
      return instant.toString();
    }
  }

  public String format(String pattern) {
    return formatGMT(pattern);
  }

  @Override
  public String toString() {
    return instant.toString();
  }

  @Override
  public boolean equals(Object other) {
    if (this == other) {
      return true;
    }
    if (!(other instanceof DateTime that)) {
      return false;
    }
    return instant.equals(that.instant);
  }

  @Override
  public int hashCode() {
    return Objects.hash(instant);
  }
}
