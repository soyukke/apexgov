package apexemu.runtime;

public interface RecordTypeInfo {
  ApexSObject getRecordTypeInfo();

  String getName();

  String getRecordTypeId();

  String getDeveloperName();

  boolean isAvailable();

  boolean isDefaultRecordTypeMapping();

  boolean isMaster();

  default boolean isActive() {
    return isAvailable();
  }

  @SuppressWarnings("unchecked")
  default <T> T getAs(String field) {
    ApexSObject recordTypeInfo = getRecordTypeInfo();
    if (recordTypeInfo == null) {
      return null;
    }
    return (T) recordTypeInfo.getAs(field);
  }
}
