package apexemu.runtime;

import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.Locale;
import java.util.Objects;

public final class DateTime implements Comparable<DateTime> {
  private final Instant instant;

  private DateTime(Instant instant) {
    this.instant = instant == null ? Instant.EPOCH : instant;
  }

  public static DateTime now() {
    return new DateTime(Instant.now());
  }

  public static DateTime Now() {
    return now();
  }

  public static DateTime newInstance(
      int year, int month, int day, int hour, int minute, int second) {
    ZonedDateTime local = ZonedDateTime.of(year, month, day, hour, minute, second, 0, ZoneOffset.UTC);
    return new DateTime(local.toInstant());
  }

  public static DateTime newInstance(int year, int month, int day) {
    return newInstance(year, month, day, 0, 0, 0);
  }

  public static DateTime newInstance(Date date, Time time) {
    if (date == null) {
      return null;
    }
    LocalDate localDate = date.value();
    LocalTime localTime = time == null ? LocalTime.MIDNIGHT : time.value();
    return new DateTime(ZonedDateTime.of(localDate, localTime, ZoneOffset.UTC).toInstant());
  }

  public static DateTime newInstance(long milliseconds) {
    return new DateTime(Instant.ofEpochMilli(milliseconds));
  }

  public static DateTime newInstanceGmt(
      int year, int month, int day, int hour, int minute, int second) {
    ZonedDateTime gmt = ZonedDateTime.of(year, month, day, hour, minute, second, 0, ZoneOffset.UTC);
    return new DateTime(gmt.toInstant());
  }

  public static DateTime newInstanceGMT(
      int year, int month, int day, int hour, int minute, int second) {
    return newInstanceGmt(year, month, day, hour, minute, second);
  }

  public static DateTime fromDate(Date value) {
    if (value == null) {
      return null;
    }
    LocalDate date = value.value();
    return new DateTime(date.atStartOfDay(ZoneOffset.UTC).toInstant());
  }

  public static DateTime valueOf(String value) {
    if (value == null || value.isBlank()) {
      return null;
    }
    Instant parsed = parseInstant(value.trim());
    return parsed == null ? null : new DateTime(parsed);
  }

  public static DateTime valueOf(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof DateTime dateTime) {
      return dateTime;
    }
    if (value instanceof Date date) {
      return fromDate(date);
    }
    if (value instanceof Number number) {
      return newInstance(number.longValue());
    }
    return valueOf(String.valueOf(value));
  }

  public static DateTime valueOfGMT(String value) {
    return valueOf(value);
  }

  public static DateTime parse(String value) {
    return valueOf(value);
  }

  public static DateTime Parse(String value) {
    return parse(value);
  }

  public long getTime() {
    return instant.toEpochMilli();
  }

  public Long hourGmt() {
    return Long.valueOf(ZonedDateTime.ofInstant(instant, ZoneOffset.UTC).getHour());
  }

  public Long minuteGmt() {
    return Long.valueOf(ZonedDateTime.ofInstant(instant, ZoneOffset.UTC).getMinute());
  }

  public Long secondGmt() {
    return Long.valueOf(ZonedDateTime.ofInstant(instant, ZoneOffset.UTC).getSecond());
  }

  public Integer year() {
    return Integer.valueOf(ZonedDateTime.ofInstant(instant, ZoneOffset.UTC).getYear());
  }

  public Integer month() {
    return Integer.valueOf(ZonedDateTime.ofInstant(instant, ZoneOffset.UTC).getMonthValue());
  }

  public Integer day() {
    return Integer.valueOf(ZonedDateTime.ofInstant(instant, ZoneOffset.UTC).getDayOfMonth());
  }

  public Integer dayGmt() {
    return day();
  }

  public Integer dayGMT() {
    return day();
  }

  public DateTime addSeconds(int seconds) {
    return new DateTime(instant.plusSeconds(seconds));
  }

  public DateTime addDays(int days) {
    return new DateTime(instant.plusSeconds((long) days * 24L * 60L * 60L));
  }

  public DateTime addHours(int hours) {
    return new DateTime(instant.plusSeconds((long) hours * 60L * 60L));
  }

  public DateTime addMinutes(int minutes) {
    return new DateTime(instant.plusSeconds((long) minutes * 60L));
  }

  public DateTime addMonths(int months) {
    return new DateTime(ZonedDateTime.ofInstant(instant, ZoneOffset.UTC).plusMonths(months).toInstant());
  }

  public DateTime addYears(int years) {
    return new DateTime(ZonedDateTime.ofInstant(instant, ZoneOffset.UTC).plusYears(years).toInstant());
  }

  public Date date() {
    ZonedDateTime utc = ZonedDateTime.ofInstant(instant, ZoneOffset.UTC);
    return Date.newInstance(utc.getYear(), utc.getMonthValue(), utc.getDayOfMonth());
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

  public String formatGmt(String pattern) {
    return formatGMT(pattern);
  }

  public String format(String pattern) {
    return formatGMT(pattern);
  }

  public String format(String pattern, String timeZoneId) {
    if (pattern == null || pattern.isBlank()) {
      return instant.toString();
    }
    ZoneId zone = ZoneOffset.UTC;
    if (timeZoneId != null && !timeZoneId.isBlank()) {
      try {
        zone = ZoneId.of(timeZoneId.trim());
      } catch (RuntimeException ignored) {
        zone = ZoneOffset.UTC;
      }
    }
    try {
      DateTimeFormatter formatter = DateTimeFormatter.ofPattern(pattern, Locale.US);
      return formatter.format(ZonedDateTime.ofInstant(instant, zone));
    } catch (IllegalArgumentException ignored) {
      return instant.toString();
    }
  }

  @Override
  public int compareTo(DateTime other) {
    if (other == null) {
      return 1;
    }
    return instant.compareTo(other.instant);
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

  private static Instant parseInstant(String text) {
    try {
      return Instant.parse(text);
    } catch (DateTimeParseException ignored) {
      // fall through
    }
    try {
      return OffsetDateTime.parse(text, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant();
    } catch (DateTimeParseException ignored) {
      // fall through
    }
    try {
      return LocalDateTime.parse(text, DateTimeFormatter.ISO_LOCAL_DATE_TIME).toInstant(ZoneOffset.UTC);
    } catch (DateTimeParseException ignored) {
      // fall through
    }
    try {
      return LocalDateTime.parse(text, DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"))
          .toInstant(ZoneOffset.UTC);
    } catch (DateTimeParseException ignored) {
      // fall through
    }
    try {
      return LocalDateTime.parse(text, DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS"))
          .toInstant(ZoneOffset.UTC);
    } catch (DateTimeParseException ignored) {
      // fall through
    }
    try {
      return OffsetDateTime.parse(text, DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSZ"))
          .toInstant();
    } catch (DateTimeParseException ignored) {
      // fall through
    }
    try {
      return OffsetDateTime.parse(text, DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssZ"))
          .toInstant();
    } catch (DateTimeParseException ignored) {
      return null;
    }
  }
}
