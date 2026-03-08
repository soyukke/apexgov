package apexemu.runtime;

public interface RecordTypeInfo {
  ApexSObject getRecordTypeInfo();

  String getName();

  String getRecordTypeId();

  String getDeveloperName();

  boolean isAvailable();

  boolean isDefaultRecordTypeMapping();

  boolean isMaster();
}
