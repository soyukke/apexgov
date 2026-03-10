package samples;

import apexemu.annotations.Test;
import apexemu.runtime.Schema;
import apexemu.runtime.SystemAssert;

public final class SchemaDescribeFieldResultTest {
  @Test
  public void exposesDisplayTypeFieldAlias() {
    Schema.DescribeFieldResult describe = new Schema.SObjectField("DataImportBatch__c", "Batch_Number__c").getDescribe();
    Schema.SObjectField field = new Schema.SObjectField("DataImportBatch__c", "Batch_Number__c");

    SystemAssert.assertEquals(describe.getType(), describe.type, "DisplayType field alias mismatch");
    SystemAssert.assertEquals(Schema.DisplayType.STRING, describe.type, "Unexpected default display type");
    SystemAssert.assertEquals(field, field.getSObjectField(), "Field self alias mismatch");
    SystemAssert.assertEquals(describe.getLabel(), field.getLabel(), "Field label alias mismatch");
    SystemAssert.assertEquals(describe.isFilterable(), field.isFilterable(), "Field filterable alias mismatch");
    SystemAssert.assertEquals(describe.isEncrypted(), field.isEncrypted(), "Field encrypted alias mismatch");
  }
}
