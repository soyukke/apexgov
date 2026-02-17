package apexemu.runtime;

public final class Http {
  public HttpResponse send(HttpRequest request) {
    Limits.addCallout(1);
    HttpCalloutMock mock = Test.getMock(HttpCalloutMock.class);
    if (mock == null) {
      throw new IllegalStateException("Http callout mock is not registered. Use Test.setMock(HttpCalloutMock.class, ...).");
    }
    HttpResponse response = mock.respond(request);
    return response == null ? new HttpResponse() : response;
  }
}
