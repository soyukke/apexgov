package apexemu.runtime;

import java.time.LocalTime;
import java.time.format.DateTimeFormatter;
import java.util.Objects;

public final class Time {
  private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("HH:mm:ss.SSS");

  private final LocalTime value;

  private Time(LocalTime value) {
    this.value = value == null ? LocalTime.MIDNIGHT : value;
  }

  public static Time newInstance(int hour, int minute, int second, int millisecond) {
    int nanos = Math.max(0, millisecond) * 1_000_000;
    return new Time(LocalTime.of(hour, minute, second, nanos));
  }

  LocalTime value() {
    return value;
  }

  @Override
  public String toString() {
    return FORMATTER.format(value);
  }

  @Override
  public boolean equals(Object other) {
    if (this == other) {
      return true;
    }
    if (!(other instanceof Time that)) {
      return false;
    }
    return value.equals(that.value);
  }

  @Override
  public int hashCode() {
    return Objects.hash(value);
  }
}
