package apexemu.runtime;

import java.util.Map;

public interface WebServiceMock {
  void doInvoke(
      Object stub,
      Object request,
      Map<String, Object> response,
      String endpoint,
      String soapAction,
      String requestName,
      String responseNamespace,
      String responseName,
      String responseType);
}
