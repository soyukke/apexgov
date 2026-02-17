package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public final class WebServiceCallout {
  private WebServiceCallout() {}

  public static Map<String, Object> invoke(
      Object stub,
      Object request,
      String endpoint,
      String soapAction,
      String requestName,
      String responseNamespace,
      String responseName,
      String responseType) {
    Limits.addCallout(1);
    WebServiceMock mock = Test.getMock(WebServiceMock.class);
    if (mock == null) {
      throw new IllegalStateException(
          "WebService mock is not registered. Use Test.setMock(WebServiceMock.class, ...).");
    }
    Map<String, Object> response = new LinkedHashMap<>();
    mock.doInvoke(
        stub,
        request,
        response,
        endpoint,
        soapAction,
        requestName,
        responseNamespace,
        responseName,
        responseType);
    return Map.copyOf(response);
  }
}
