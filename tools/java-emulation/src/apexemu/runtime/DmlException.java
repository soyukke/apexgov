package apexemu.runtime;

import java.util.ArrayList;
import java.util.List;

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

  public Integer getNumDml() {
    return 1;
  }

  public String getDmlMessage(int index) {
    return getMessage();
  }

  public String getDmlMessage(Integer index) {
    return getMessage();
  }

  public List<String> getDmlFieldNames(Integer index) {
    return new ArrayList<>();
  }
}
