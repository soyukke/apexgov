package samples;

import apexemu.annotations.Test;
import apexemu.runtime.ApexSObject;
import apexemu.runtime.CampaignMember;
import apexemu.runtime.ApexPages;
import apexemu.runtime.Date;
import apexemu.runtime.DateTime;
import apexemu.runtime.HttpResponse;
import apexemu.runtime.ApexInterfaceAdapter;
import apexemu.runtime.Metadata;
import apexemu.runtime.Schema;
import apexemu.runtime.System;
import apexemu.runtime.SystemAssert;

public final class RuntimeCompatibilityTest {
  @Test
  public void exposesMetadataAndSystemCompatibilityAliases() {
    Metadata.DeployMessage message = new Metadata.DeployMessage();
    message.fullName = "Pkg.Member";
    message.problem = "Broken";

    Metadata.CustomMetadata metadata = new Metadata.CustomMetadata();
    metadata.description = "desc";
    metadata.protected_x = true;

    System.SecurityException ex = new System.SecurityException();
    Long now = System.currentTimeMillis();
    Schema.SObjectField campaignId = CampaignMember.CampaignId;
    Date today = Date.Today();
    ApexPages.addmessage(new ApexPages.Message(ApexPages.Severity.ERROR, "compat"));
    ApexPages.StandardSetController setController =
        new ApexPages.StandardSetController(java.util.List.of());
    HttpResponse response = new HttpResponse();
    response.setHeader("X-Test", "ok");
    DateTime parsedDateTime = DateTime.valueOfGMT("2024-03-04 05:06:07");
    System.CalloutException callout = new System.CalloutException("timeout");
    Metadata.CustomMetadata customMetadata = new Metadata.CustomMetadata();
    customMetadata.values.add(new Metadata.CustomMetadataValue());

    SystemAssert.assertEquals("Pkg.Member", message.fullName, "Deploy message fullName alias mismatch");
    SystemAssert.assertEquals("Broken", message.problem, "Deploy message problem alias mismatch");
    SystemAssert.assertEquals("desc", metadata.description, "Custom metadata description alias mismatch");
    SystemAssert.assertEquals(Boolean.TRUE, metadata.protected_x, "Custom metadata protected alias mismatch");
    SystemAssert.assertEquals(null, ex.getMessage(), "Default security exception message should be null");
    SystemAssert.assertTrue(
        now != null && now > 0L, "currentTimeMillis alias should return a positive timestamp");
    SystemAssert.assertEquals("CampaignId", campaignId.getDescribe().getName(), "CampaignId token alias mismatch");
    SystemAssert.assertEquals(today.year(), today.Year(), "Date Year alias mismatch");
    SystemAssert.assertEquals(today.month(), today.Month(), "Date Month alias mismatch");
    SystemAssert.assertEquals(today.day(), today.Day(), "Date Day alias mismatch");
    SystemAssert.assertTrue(today.isSameDay(Date.valueOf(today.toString())), "Date isSameDay alias mismatch");
    SystemAssert.assertEquals("2024-03-04T05:06:07Z", String.valueOf(parsedDateTime), "DateTime valueOfGMT alias mismatch");
    SystemAssert.assertEquals("2024", parsedDateTime.formatGmt("yyyy"), "DateTime formatGmt alias mismatch");
    SystemAssert.assertEquals("2024-03-04T00:00:00Z", String.valueOf(DateTime.valueOf(Date.valueOf("2024-03-04"))), "DateTime valueOf(Date) alias mismatch");
    SystemAssert.assertTrue(DateTime.Now() != null, "DateTime Now alias mismatch");
    SystemAssert.assertEquals(java.util.List.of("X-Test"), response.getHeaderKeys(), "HttpResponse header key alias mismatch");
    SystemAssert.assertEquals("timeout", callout.getMessage(), "CalloutException alias mismatch");
    SystemAssert.assertEquals(1, customMetadata.values().size(), "Metadata CustomMetadata values() alias mismatch");
    SystemAssert.assertNotEquals(null, "ok", java.util.Map.of("status", "ok"));
    SystemAssert.assertTrue(ApexPages.hasMessages(ApexPages.Severity.ERROR), "ApexPages addmessage alias should record messages");
    setController.setSelected(java.util.List.of());
    SystemAssert.assertEquals(0, setController.getSelected().size(), "StandardSetController setSelected alias mismatch");

    AdapterProbe.instance = null;
    SystemAssert.assertEquals(
        "pong",
        AdapterProbe.getInstance().ping(),
        "ApexInterfaceAdapter should proxy self-interface singleton instances");
    AdapterProbe.instance = (AdapterProbe.Contract) () -> "stub";
    SystemAssert.assertEquals(
        "stub",
        AdapterProbe.getInstance().ping(),
        "ApexInterfaceAdapter should return directly assignable interface instances");
  }

  private static final class AdapterProbe {
    interface Contract {
      String ping();
    }

    static Object instance;

    static Contract getInstance() {
      if (instance == null) {
        instance = new AdapterProbe();
      }
      return ApexInterfaceAdapter.adapt(instance, Contract.class);
    }

    String ping() {
      return "pong";
    }
  }

  @Test
  public void systemTypeSupportsSObjectInstantiationAndTypeExceptionCatchability() {
    Object customObject = System.Type.forName("DataImportBatch__c").newInstance();
    Object standardObject = System.Type.forName("CollaborationGroup").newInstance();
    Object opportunityObject = System.Type.forName("Opportunity").newInstance();

    SystemAssert.assertTrue(customObject instanceof ApexSObject, "Custom SObject type should instantiate as ApexSObject");
    SystemAssert.assertTrue(standardObject instanceof ApexSObject, "Standard SObject type should instantiate as ApexSObject");
    SystemAssert.assertTrue(opportunityObject instanceof ApexSObject, "Built-in SObject type should instantiate as ApexSObject");
    SystemAssert.assertEquals("DataImportBatch__c", ((ApexSObject) customObject).type(), "Custom SObject type token mismatch");
    SystemAssert.assertEquals("CollaborationGroup", ((ApexSObject) standardObject).type(), "Standard SObject type token mismatch");
    SystemAssert.assertEquals("Opportunity", ((ApexSObject) opportunityObject).type(), "Built-in SObject type token mismatch");

    Boolean caughtAsBaseException = false;
    try {
      throw new System.TypeException("invalid");
    } catch (System.Exception ignored) {
      caughtAsBaseException = true;
    }
    SystemAssert.assertEquals(true, caughtAsBaseException, "TypeException should be catchable via System.Exception");
  }
}
