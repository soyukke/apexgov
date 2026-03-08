package apexemu.runtime;

import java.time.LocalDate;

public final class Date {
  private final LocalDate value;

  private Date(LocalDate value) {
    this.value = value;
  }

  public static Date newInstance(int year, int month, int day) {
    return new Date(LocalDate.of(year, month, day));
  }

  public static Date today() {
    return new Date(LocalDate.now());
  }

  public Date addDays(int days) {
    return new Date(value.plusDays(days));
  }

  public Date addMonths(int months) {
    return new Date(value.plusMonths(months));
  }

  LocalDate value() {
    return value;
  }

  public Integer year() {
    return value.getYear();
  }

  public Integer month() {
    return value.getMonthValue();
  }

  public Integer day() {
    return value.getDayOfMonth();
  }

  @Override
  public String toString() {
    return value.toString();
  }
}
