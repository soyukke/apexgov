package apexemu.runtime;

public class CampaignMember extends ApexSObject {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("CampaignMember");
  public static final Schema.SObjectField CampaignId =
      new Schema.SObjectField("CampaignMember", "CampaignId");
  public static final Schema.SObjectField Status =
      new Schema.SObjectField("CampaignMember", "Status");

  public CampaignMember() {
    super("CampaignMember");
  }
}
