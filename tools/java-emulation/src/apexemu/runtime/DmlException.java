package apexemu.runtime;

public class DmlException extends System.Exception {
  public DmlException() {
    super();
  }

  public DmlException(String message) {
    super(message);
  }

  public DmlException(String message, Throwable cause) {
    super(message, cause);
  }
}
