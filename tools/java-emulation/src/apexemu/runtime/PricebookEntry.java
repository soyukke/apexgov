package apexemu.runtime;

public class PricebookEntry extends ApexSObject {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("PricebookEntry");
  public static final Schema.SObjectField Id = new Schema.SObjectField("PricebookEntry", "Id");
  public static final Schema.SObjectField Name = new Schema.SObjectField("PricebookEntry", "Name");
  public static final Schema.SObjectField Product2Id =
      new Schema.SObjectField("PricebookEntry", "Product2Id");
  public static final Schema.SObjectField Pricebook2Id =
      new Schema.SObjectField("PricebookEntry", "Pricebook2Id");
  public static final Schema.SObjectField UnitPrice =
      new Schema.SObjectField("PricebookEntry", "UnitPrice");

  public PricebookEntry() {
    super("PricebookEntry");
  }
}
