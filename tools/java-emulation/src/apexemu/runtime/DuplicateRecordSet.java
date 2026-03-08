package apexemu.runtime;

public class DuplicateRecordSet extends ApexSObject {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("DuplicateRecordSet");
  public static final Schema.SObjectType sObjectType = SObjectType;

  public DuplicateRecordSet() {
    super("DuplicateRecordSet");
  }
}
