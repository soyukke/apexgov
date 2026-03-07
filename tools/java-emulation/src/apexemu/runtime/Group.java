package apexemu.runtime;

public class Group extends ApexSObject {
  public static final Schema.SObjectType SObjectType = new Schema.SObjectType("Group");
  public static final Schema.SObjectField Id = new Schema.SObjectField("Group", "Id");
  public static final Schema.SObjectField Name = new Schema.SObjectField("Group", "Name");

  public Group() {
    super("Group");
  }
}
