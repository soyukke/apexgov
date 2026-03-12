package apexemu.runtime;

public class CampaignMemberStatus extends ApexSObject {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("CampaignMemberStatus");
  public String label;
  public Boolean hasResponded;

  public CampaignMemberStatus() {
    super("CampaignMemberStatus");
  }

  @Override
  public CampaignMemberStatus withId(String id) {
    super.withId(id);
    return this;
  }

  @Override
  public CampaignMemberStatus set(String field, Object value) {
    super.set(field, value);
    if (field != null) {
      if (field.equalsIgnoreCase("Label")) {
        label = value == null ? null : String.valueOf(value);
      } else if (field.equalsIgnoreCase("HasResponded")) {
        hasResponded = value == null ? null : Boolean.valueOf(String.valueOf(value));
      }
    }
    return this;
  }

  @Override
  public CampaignMemberStatus set(Schema.SObjectField field, Object value) {
    super.set(field, value);
    return this;
  }
}
