package apexemu.runtime;

import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.temporal.TemporalAdjusters;

public final class Date implements Comparable<Date> {
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

  public static Date Today() {
    return today();
  }

  public static Date valueOf(String value) {
    if (value == null || value.isBlank()) {
      return null;
    }
    return new Date(LocalDate.parse(value));
  }

  public static Date valueOf(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof Date date) {
      return date;
    }
    return valueOf(String.valueOf(value));
  }

  public Date addDays(int days) {
    return new Date(value.plusDays(days));
  }

  public Date addMonths(int months) {
    return new Date(value.plusMonths(months));
  }

  public Date addYears(int years) {
    return new Date(value.plusYears(years));
  }

  public Integer daysBetween(Date other) {
    if (other == null) {
      return null;
    }
    return (int) (other.value.toEpochDay() - value.toEpochDay());
  }

  public Date toStartOfMonth() {
    return new Date(value.withDayOfMonth(1));
  }

  public Date toStartOfWeek() {
    return new Date(value.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY)));
  }

  public Boolean isSameDay(Date other) {
    if (other == null) {
      return false;
    }
    return value.equals(other.value);
  }

  LocalDate value() {
    return value;
  }

  public Integer year() {
    return value.getYear();
  }

  public Integer Year() {
    return year();
  }

  public Integer month() {
    return value.getMonthValue();
  }

  public Integer Month() {
    return month();
  }

  public Integer day() {
    return value.getDayOfMonth();
  }

  public Integer Day() {
    return day();
  }

  @Override
  public int compareTo(Date other) {
    if (other == null) {
      return 1;
    }
    return value.compareTo(other.value);
  }

  @Override
  public String toString() {
    return value.toString();
  }
}
