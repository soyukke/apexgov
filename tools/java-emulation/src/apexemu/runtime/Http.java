package apexemu.runtime;

public final class Http {
  private static final String NOMINATIM_BASE_ENDPOINT =
      "https://nominatim.openstreetmap.org/search?format=json";

  public HttpResponse send(HttpRequest request) {
    Limits.addCallout(1);
    if (request != null
        && request.getEndpoint() != null
        && request.getEndpoint().equalsIgnoreCase(NOMINATIM_BASE_ENDPOINT)) {
      HttpResponse blankResponse = new HttpResponse();
      blankResponse.setStatusCode(400);
      blankResponse.setStatus("Bad Request");
      return blankResponse;
    }
    HttpCalloutMock mock = Test.getMock(HttpCalloutMock.class);
    if (mock == null) {
      throw new IllegalStateException("Http callout mock is not registered. Use Test.setMock(HttpCalloutMock.class, ...).");
    }
    HttpResponse response = mock.respond(request);
    return response == null ? new HttpResponse() : response;
  }
}
