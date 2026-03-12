package apexemu.runtime;

public class AsyncApexJob extends ApexSObject {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("AsyncApexJob");
  public Integer jobItemsProcessed;
  public Integer totalJobItems;

  public AsyncApexJob() {
    super("AsyncApexJob");
  }
}
