package samples;

import apexemu.annotations.Test;
import apexemu.runtime.JSON;
import apexemu.runtime.JSONGenerator;
import apexemu.runtime.SystemAssert;

public final class JsonGeneratorTest {
  @Test
  public void writesStringFieldIntoObject() {
    JSONGenerator generator = JSON.createGenerator(false);
    generator.writeStartObject();
    generator.writeStringField("status", "ok");
    generator.writeEndObject();

    SystemAssert.assertEquals("{\"status\":\"ok\"}", generator.getAsString(), "JSON string field mismatch");
  }
}
