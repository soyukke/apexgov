package apexemu.runtime;

public class QueryException extends System.QueryException {
  public QueryException() {
    super();
  }

  public QueryException(String message) {
    super(message);
  }

  public QueryException(String message, Throwable cause) {
    super(message, cause);
  }
}
