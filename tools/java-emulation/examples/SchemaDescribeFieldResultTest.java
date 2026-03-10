package samples;

import apexemu.annotations.Test;
import apexemu.runtime.Schema;
import apexemu.runtime.SystemAssert;

public final class SchemaDescribeFieldResultTest {
  @Test
  public void exposesDisplayTypeFieldAlias() {
    Schema.DescribeFieldResult describe = new Schema.SObjectField("DataImportBatch__c", "Batch_Number__c").getDescribe();

    SystemAssert.assertEquals(describe.getType(), describe.type, "DisplayType field alias mismatch");
    SystemAssert.assertEquals(Schema.DisplayType.STRING, describe.type, "Unexpected default display type");
  }
}
