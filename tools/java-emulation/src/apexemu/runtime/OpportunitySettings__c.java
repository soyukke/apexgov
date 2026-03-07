package apexemu.runtime;

public final class OpportunitySettings__c {
  private OpportunitySettings__c() {}

  public static ApexSObject getInstance() {
    return ApexSObject.of("OpportunitySettings__c").set("DiscountType__c", "Approved Products");
  }
}
