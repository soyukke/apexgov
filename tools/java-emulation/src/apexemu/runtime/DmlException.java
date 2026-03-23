package apexemu.runtime;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public class DmlException extends System.Exception {
  private final List<DmlInfo> dmlInfos = new ArrayList<>();

  public DmlException() {
    super();
  }

  public DmlException(String message) {
    super(message);
  }

  public DmlException(String message, Throwable cause) {
    super(message, cause);
  }

  public void addDmlInfo(String statusCode, String message, String[] fields) {
    dmlInfos.add(new DmlInfo(
        statusCode == null ? "DML_ERROR" : statusCode,
        message == null ? "" : message,
        fields == null ? new String[0] : fields.clone()));
  }

  public Integer getNumDml() {
    return dmlInfos.isEmpty() ? 1 : dmlInfos.size();
  }

  public String getDmlMessage(int index) {
    if (index >= 0 && index < dmlInfos.size()) {
      return dmlInfos.get(index).message;
    }
    return getMessage();
  }

  public String getDmlMessage(Integer index) {
    return getDmlMessage(index == null ? 0 : index.intValue());
  }

  public String getDmlStatusCode(int index) {
    if (index >= 0 && index < dmlInfos.size()) {
      return dmlInfos.get(index).statusCode;
    }
    return "DML_ERROR";
  }

  public String getDmlStatusCode(Integer index) {
    return getDmlStatusCode(index == null ? 0 : index.intValue());
  }

  public String getDmlType(int index) {
    return getDmlStatusCode(index);
  }

  public String getDmlType(Integer index) {
    return getDmlStatusCode(index);
  }

  public List<String> getDmlFieldNames(int index) {
    if (index >= 0 && index < dmlInfos.size()) {
      return new ArrayList<>(Arrays.asList(dmlInfos.get(index).fields));
    }
    return new ArrayList<>();
  }

  public List<String> getDmlFieldNames(Integer index) {
    return getDmlFieldNames(index == null ? 0 : index.intValue());
  }

  public String getDmlId(int index) {
    return null;
  }

  public String getDmlId(Integer index) {
    return null;
  }

  private record DmlInfo(String statusCode, String message, String[] fields) {}
}
