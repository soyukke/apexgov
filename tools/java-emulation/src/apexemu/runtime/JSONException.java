package apexemu.runtime;

public class JSONException extends System.JSONException {
  public JSONException() {
    super();
  }

  public JSONException(String message) {
    super(message);
  }

  public JSONException(String message, Throwable cause) {
    super(message, cause);
  }
}
