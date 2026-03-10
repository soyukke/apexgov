package samples;

import apexemu.annotations.Test;
import apexemu.runtime.CampaignMember;
import apexemu.runtime.Date;
import apexemu.runtime.ApexPages;
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
    SystemAssert.assertTrue(ApexPages.hasMessages(ApexPages.Severity.ERROR), "ApexPages addmessage alias should record messages");
    setController.setSelected(java.util.List.of());
    SystemAssert.assertEquals(0, setController.getSelected().size(), "StandardSetController setSelected alias mismatch");
  }
}
