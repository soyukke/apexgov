package apexemu.runtime;

public class CampaignMember extends ApexSObject {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("CampaignMember");
  public static final Schema.SObjectField ContactId =
      new Schema.SObjectField("CampaignMember", "ContactId");
  public static final Schema.SObjectField CampaignId =
      new Schema.SObjectField("CampaignMember", "CampaignId");
  public static final Schema.SObjectField Status =
      new Schema.SObjectField("CampaignMember", "Status");
  public String contactId;
  public String campaignId;
  public Boolean hasResponded;

  public CampaignMember() {
    super("CampaignMember");
  }

  @Override
  public CampaignMember withId(String id) {
    super.withId(id);
    return this;
  }

  @Override
  public CampaignMember set(String field, Object value) {
    super.set(field, value);
    if (field != null) {
      if (field.equalsIgnoreCase("ContactId")) {
        contactId = value == null ? null : String.valueOf(value);
      } else if (field.equalsIgnoreCase("CampaignId")) {
        campaignId = value == null ? null : String.valueOf(value);
      } else if (field.equalsIgnoreCase("HasResponded")) {
        hasResponded = value == null ? null : Boolean.valueOf(String.valueOf(value));
      }
    }
    return this;
  }

  @Override
  public CampaignMember set(Schema.SObjectField field, Object value) {
    super.set(field, value);
    return this;
  }
}
