package apexemu.runtime;

public final class LoggingLevel {
  public static final System.LoggingLevel WARN = System.LoggingLevel.WARN;
  public static final System.LoggingLevel INFO = System.LoggingLevel.INFO;
  public static final System.LoggingLevel ERROR = System.LoggingLevel.ERROR;
  public static final System.LoggingLevel DEBUG = System.LoggingLevel.DEBUG;
  public static final System.LoggingLevel FINE = System.LoggingLevel.TRACE;
  public static final System.LoggingLevel warn = WARN;
  public static final System.LoggingLevel info = INFO;
  public static final System.LoggingLevel error = ERROR;
  public static final System.LoggingLevel debug = DEBUG;
  public static final System.LoggingLevel fine = FINE;

  private LoggingLevel() {}
}
