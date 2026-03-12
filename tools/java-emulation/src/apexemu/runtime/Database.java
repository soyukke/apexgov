package apexemu.runtime;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class Database {
  private Database() {}

  public interface Batchable<T> extends apexemu.runtime.Batchable<T> {}

  public interface Stateful {}

  public interface AllowsCallouts {}

  public interface RaisesPlatformEvents {}

  public static String executeBatch(apexemu.runtime.Batchable<?> job) {
    return Async.enqueueBatch((apexemu.runtime.Batchable) job, 200);
  }

  @SuppressWarnings("unchecked")
  public static String executeBatch(apexemu.runtime.Batchable<?> job, int scopeSize) {
    return Async.enqueueBatch((apexemu.runtime.Batchable) job, scopeSize);
  }

  public static String executeBatch(java.util.function.IntConsumer work, int scopeSize) {
    if (work == null) {
      throw new IllegalArgumentException("batch job cannot be null");
    }
    return executeBatch(
        new apexemu.runtime.Batchable<Object>() {
          @Override
          public void execute(int size) {
            work.accept(size);
          }
        },
        scopeSize);
  }

  public static String executeBatch(QueryLocatorBatchable job) {
    return executeBatch(job, 200);
  }

  public static String executeBatch(QueryLocatorBatchable job, int scopeSize) {
    return Async.enqueueBatch(job, scopeSize);
  }

  public static LeadConvertResult convertLead(LeadConvert leadConvert) {
    if (leadConvert == null) {
      return new LeadConvertResult(false, null, new Error[0], null, null, null, null);
    }
    return new LeadConvertResult(
        true,
        leadConvert.getContactId(),
        new Error[0],
        leadConvert.getLeadId(),
        leadConvert.getContactId(),
        leadConvert.getAccountId(),
        null);
  }

  private static boolean resolveAllOrNone(DmlOptions dmlOptions) {
    if (dmlOptions == null) {
      return true;
    }
    Boolean configured = dmlOptions.getOptAllOrNone();
    return configured == null ? true : configured;
  }

  public static void insert(Collection<? extends ApexSObject> records) {
    ensureSuccess(insert(records, true), "insert");
  }

  public static SaveResult insert(ApexSObject record) {
    if (record == null) {
      return null;
    }
    SaveResult[] results = insert((Collection<? extends ApexSObject>) List.of(record), true);
    ensureSuccess(results, "insert");
    return results.length == 0 ? null : results[0];
  }

  public static SaveResult insert(Object record) {
    return insert(asSObject(record));
  }

  public static SaveResult insert(ApexSObject record, boolean allOrNone) {
    if (record == null) {
      return null;
    }
    SaveResult[] results = insert((Collection<? extends ApexSObject>) List.of(record), allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "insert");
    }
    return results.length == 0 ? null : results[0];
  }

  public static SaveResult insert(Object record, boolean allOrNone) {
    return insert(asSObject(record), allOrNone);
  }

  public static SaveResult insert(ApexSObject record, DmlOptions dmlOptions) {
    return insert(record, resolveAllOrNone(dmlOptions));
  }

  public static SaveResult insert(Object record, DmlOptions dmlOptions) {
    return insert(asSObject(record), dmlOptions);
  }

  public static SaveResult insert(ApexSObject record, System.AccessLevel accessLevel) {
    return insert(record, true, accessLevel);
  }

  public static SaveResult insert(Object record, System.AccessLevel accessLevel) {
    return insert(asSObject(record), true, accessLevel);
  }

  public static SaveResult insert(
      ApexSObject record, boolean allOrNone, System.AccessLevel accessLevel) {
    if (record == null) {
      return null;
    }
    enforceUserModeDmlAccess(List.of(record), accessLevel, UserModeOperation.CREATE);
    SaveResult[] results = insert((Collection<? extends ApexSObject>) List.of(record), allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "insert");
    }
    return results.length == 0 ? null : results[0];
  }

  public static SaveResult insert(Object record, boolean allOrNone, System.AccessLevel accessLevel) {
    return insert(asSObject(record), allOrNone, accessLevel);
  }

  public static List<SaveResult> insert(List<? extends ApexSObject> records) {
    return insert(records, true);
  }

  public static List<SaveResult> insert(List<? extends ApexSObject> records, boolean allOrNone) {
    SaveResult[] results = insert((Collection<? extends ApexSObject>) records, allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "insert");
    }
    return toSaveResultList(results);
  }

  public static List<SaveResult> insert(List<? extends ApexSObject> records, System.AccessLevel accessLevel) {
    return insert(records, true, accessLevel);
  }

  public static List<SaveResult> insert(List<? extends ApexSObject> records, DmlOptions dmlOptions) {
    return insert(records, resolveAllOrNone(dmlOptions));
  }

  public static List<SaveResult> insert(
      List<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.CREATE);
    return insert(records, allOrNone);
  }

  public static void update(Collection<? extends ApexSObject> records) {
    ensureSuccess(update(records, true), "update");
  }

  public static SaveResult update(ApexSObject record) {
    if (record == null) {
      return null;
    }
    SaveResult[] results = update((Collection<? extends ApexSObject>) List.of(record), true);
    ensureSuccess(results, "update");
    return results.length == 0 ? null : results[0];
  }

  public static SaveResult update(ApexSObject record, boolean allOrNone) {
    if (record == null) {
      return null;
    }
    SaveResult[] results = update((Collection<? extends ApexSObject>) List.of(record), allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "update");
    }
    return results.length == 0 ? null : results[0];
  }

  public static SaveResult update(Object record, boolean allOrNone) {
    return update(asSObject(record), allOrNone);
  }

  public static SaveResult update(ApexSObject record, DmlOptions dmlOptions) {
    return update(record, resolveAllOrNone(dmlOptions));
  }

  public static SaveResult update(Object record, DmlOptions dmlOptions) {
    return update(asSObject(record), dmlOptions);
  }

  public static List<SaveResult> update(List<? extends ApexSObject> records) {
    return update(records, true);
  }

  public static List<SaveResult> update(List<? extends ApexSObject> records, boolean allOrNone) {
    SaveResult[] results = update((Collection<? extends ApexSObject>) records, allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "update");
    }
    return toSaveResultList(results);
  }

  public static List<SaveResult> update(List<? extends ApexSObject> records, System.AccessLevel accessLevel) {
    return update(records, true, accessLevel);
  }

  public static List<SaveResult> update(List<? extends ApexSObject> records, DmlOptions dmlOptions) {
    return update(records, resolveAllOrNone(dmlOptions));
  }

  public static List<SaveResult> update(
      List<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.UPDATE);
    return update(records, allOrNone);
  }

  public static void upsert(Collection<? extends ApexSObject> records) {
    ensureSuccess(upsert(records, true), "upsert");
  }

  public static UpsertResult upsert(ApexSObject record) {
    if (record == null) {
      return null;
    }
    SaveResult[] results = upsert((Collection<? extends ApexSObject>) List.of(record), true);
    ensureSuccess(results, "upsert");
    return results.length == 0 ? null : toUpsertResult(results[0]);
  }

  public static UpsertResult upsert(ApexSObject record, boolean allOrNone) {
    if (record == null) {
      return null;
    }
    SaveResult[] results = upsert((Collection<? extends ApexSObject>) List.of(record), allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "upsert");
    }
    return results.length == 0 ? null : toUpsertResult(results[0]);
  }

  public static UpsertResult upsert(Object record, boolean allOrNone) {
    return upsert(asSObject(record), allOrNone);
  }

  public static UpsertResult upsert(
      ApexSObject record, boolean allOrNone, System.AccessLevel accessLevel) {
    if (record == null) {
      return null;
    }
    enforceUserModeDmlAccess(List.of(record), accessLevel, UserModeOperation.UPSERT);
    SaveResult[] results = upsert((Collection<? extends ApexSObject>) List.of(record), allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "upsert");
    }
    return results.length == 0 ? null : toUpsertResult(results[0]);
  }

  public static UpsertResult upsert(Object record, boolean allOrNone, System.AccessLevel accessLevel) {
    return upsert(asSObject(record), allOrNone, accessLevel);
  }

  public static List<UpsertResult> upsert(List<? extends ApexSObject> records) {
    return upsert(records, true);
  }

  public static List<UpsertResult> upsert(List<? extends ApexSObject> records, boolean allOrNone) {
    SaveResult[] results = upsert((Collection<? extends ApexSObject>) records, allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "upsert");
    }
    return toUpsertResultList(results);
  }

  public static List<UpsertResult> upsert(
      List<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.UPSERT);
    return upsert(records, allOrNone);
  }

  public static UpsertResult upsert(ApexSObject record, Schema.SObjectField externalIdField) {
    return upsert(record, externalIdField, true);
  }

  public static UpsertResult upsert(
      ApexSObject record,
      Schema.SObjectField externalIdField,
      boolean allOrNone) {
    if (record == null) {
      return null;
    }
    String fieldName = externalIdField == null ? null : externalIdField.getName();
    SaveResult[] results = upsert(List.of(record), fieldName, allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "upsert");
    }
    return results.length == 0 ? null : toUpsertResult(results[0]);
  }

  public static List<UpsertResult> upsert(
      List<? extends ApexSObject> records,
      Schema.SObjectField externalIdField) {
    return upsert(records, externalIdField, true);
  }

  public static List<UpsertResult> upsert(
      List<? extends ApexSObject> records,
      Schema.SObjectField externalIdField,
      boolean allOrNone) {
    String fieldName = externalIdField == null ? null : externalIdField.getName();
    SaveResult[] results = upsert((Collection<? extends ApexSObject>) records, fieldName, allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "upsert");
    }
    return toUpsertResultList(results);
  }

  public static void upsert(Collection<? extends ApexSObject> records, String externalIdFieldName) {
    ensureSuccess(upsert(records, externalIdFieldName, true), "upsert");
  }

  public static void upsert(ApexSObject record, String externalIdFieldName) {
    if (record == null) {
      return;
    }
    upsert(List.of(record), externalIdFieldName);
  }

  public static void delete(Collection<? extends ApexSObject> records) {
    ensureSuccess(delete(records, true), "delete");
  }

  public static void delete(Object recordOrRecords) {
    if (recordOrRecords == null) {
      return;
    }
    if (recordOrRecords instanceof Collection<?> records) {
      @SuppressWarnings("unchecked")
      Collection<? extends ApexSObject> normalized = (Collection<? extends ApexSObject>) records;
      delete(normalized);
      return;
    }
    delete(asSObject(recordOrRecords));
  }

  public static DeleteResult delete(ApexSObject record) {
    if (record == null) {
      throw new apexemu.runtime.System.DmlException("Attempt to de-reference a null object");
    }
    SaveResult[] results = delete((Collection<? extends ApexSObject>) List.of(record), true);
    ensureSuccess(results, "delete");
    return results.length == 0 ? null : new DeleteResult(results[0].isSuccess(), results[0].getId(), results[0].getErrors());
  }

  public static DeleteResult delete(ApexSObject record, boolean allOrNone) {
    if (record == null) {
      throw new apexemu.runtime.System.DmlException("Attempt to de-reference a null object");
    }
    SaveResult[] results = delete((Collection<? extends ApexSObject>) List.of(record), allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "delete");
    }
    return results.length == 0 ? null : new DeleteResult(results[0].isSuccess(), results[0].getId(), results[0].getErrors());
  }

  public static List<DeleteResult> delete(List<? extends ApexSObject> records, boolean allOrNone) {
    SaveResult[] results = delete((Collection<? extends ApexSObject>) records, allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "delete");
    }
    return toDeleteResultList(results);
  }

  public static List<DeleteResult> delete(List<? extends ApexSObject> records, System.AccessLevel accessLevel) {
    return delete(records, true, accessLevel);
  }

  public static List<DeleteResult> delete(
      List<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.DELETE);
    return delete(records, allOrNone);
  }

  public static void emptyRecycleBin(Collection<? extends ApexSObject> records) {
    ensureSuccess(emptyRecycleBin(records, true), "emptyRecycleBin");
  }

  public static void emptyRecycleBin(ApexSObject record) {
    if (record == null) {
      return;
    }
    emptyRecycleBin((Collection<? extends ApexSObject>) List.of(record));
  }

  public static List<DeleteResult> emptyRecycleBin(List<? extends ApexSObject> records) {
    return toDeleteResultList(emptyRecycleBin((Collection<? extends ApexSObject>) records, true));
  }

  public static List<DeleteResult> emptyRecycleBin(
      List<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    return toDeleteResultList(emptyRecycleBin((Collection<? extends ApexSObject>) records, allOrNone));
  }

  public static void undelete(Collection<? extends ApexSObject> records) {
    ensureSuccess(undelete(records, true), "undelete");
  }

  public static UndeleteResult undelete(ApexSObject record) {
    if (record == null) {
      return null;
    }
    SaveResult[] results = undelete((Collection<? extends ApexSObject>) List.of(record), true);
    ensureSuccess(results, "undelete");
    return results.length == 0 ? null : toUndeleteResult(results[0]);
  }

  public static UndeleteResult undelete(ApexSObject record, boolean allOrNone) {
    if (record == null) {
      return null;
    }
    SaveResult[] results = undelete((Collection<? extends ApexSObject>) List.of(record), allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "undelete");
    }
    return results.length == 0 ? null : toUndeleteResult(results[0]);
  }

  public static List<UndeleteResult> undelete(List<? extends ApexSObject> records) {
    return undelete(records, true);
  }

  public static List<UndeleteResult> undelete(List<? extends ApexSObject> records, boolean allOrNone) {
    SaveResult[] results = undelete((Collection<? extends ApexSObject>) records, allOrNone);
    if (allOrNone) {
      ensureSuccess(results, "undelete");
    }
    return toUndeleteResultList(results);
  }

  public static List<UndeleteResult> undelete(
      List<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.UNDELETE);
    return undelete(records, allOrNone);
  }

  public static List<UndeleteResult> undelete(List<? extends ApexSObject> records, System.AccessLevel accessLevel) {
    return undelete(records, true, accessLevel);
  }

  public static void merge(ApexSObject masterRecord, ApexSObject duplicateRecord) {
    ensureSuccess(merge(masterRecord, duplicateRecord, true), "merge");
  }

  public static void merge(ApexSObject masterRecord, Collection<? extends ApexSObject> duplicateRecords) {
    ensureSuccess(merge(masterRecord, duplicateRecords, true), "merge");
  }

  public static SaveResult[] insert(Collection<? extends ApexSObject> records, boolean allOrNone) {
    return ApexStore.insert(toApexSObjectCollection(records), allOrNone);
  }

  public static SaveResult[] insert(
      Collection<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.CREATE);
    return insert(records, allOrNone);
  }

  public static SaveResult[] insert(Collection<? extends ApexSObject> records, System.AccessLevel accessLevel) {
    return insert(records, true, accessLevel);
  }

  public static SaveResult[] update(Collection<? extends ApexSObject> records, boolean allOrNone) {
    return ApexStore.update(toApexSObjectCollection(records), allOrNone);
  }

  public static SaveResult[] update(
      Collection<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.UPDATE);
    return update(records, allOrNone);
  }

  public static SaveResult[] update(Collection<? extends ApexSObject> records, System.AccessLevel accessLevel) {
    return update(records, true, accessLevel);
  }

  public static SaveResult[] upsert(Collection<? extends ApexSObject> records, boolean allOrNone) {
    return ApexStore.upsert(toApexSObjectCollection(records), allOrNone);
  }

  public static SaveResult[] upsert(
      Collection<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.UPSERT);
    return upsert(records, allOrNone);
  }

  public static SaveResult[] upsert(Collection<? extends ApexSObject> records, System.AccessLevel accessLevel) {
    return upsert(records, true, accessLevel);
  }

  public static SaveResult[] upsert(
      Collection<? extends ApexSObject> records, String externalIdFieldName, boolean allOrNone) {
    return ApexStore.upsert(toApexSObjectCollection(records), allOrNone, externalIdFieldName);
  }

  public static SaveResult[] upsert(
      ApexSObject record, String externalIdFieldName, boolean allOrNone) {
    if (record == null) {
      return new SaveResult[0];
    }
    return upsert(List.of(record), externalIdFieldName, allOrNone);
  }

  public static SaveResult[] delete(Collection<? extends ApexSObject> records, boolean allOrNone) {
    return ApexStore.delete(toApexSObjectCollection(records), allOrNone);
  }

  public static SaveResult[] emptyRecycleBin(Collection<? extends ApexSObject> records, boolean allOrNone) {
    return delete(records, allOrNone);
  }

  public static SaveResult[] emptyRecycleBin(
      Collection<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.DELETE);
    return emptyRecycleBin(records, allOrNone);
  }

  public static SaveResult[] emptyRecycleBin(
      Collection<? extends ApexSObject> records, System.AccessLevel accessLevel) {
    return emptyRecycleBin(records, true, accessLevel);
  }

  public static SaveResult[] delete(
      Collection<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.DELETE);
    return delete(records, allOrNone);
  }

  public static SaveResult[] delete(Collection<? extends ApexSObject> records, System.AccessLevel accessLevel) {
    return delete(records, true, accessLevel);
  }

  public static SaveResult[] undelete(Collection<? extends ApexSObject> records, boolean allOrNone) {
    return ApexStore.undelete(toApexSObjectCollection(records), allOrNone);
  }

  public static SaveResult[] undelete(
      Collection<? extends ApexSObject> records, boolean allOrNone, System.AccessLevel accessLevel) {
    enforceUserModeDmlAccess(records, accessLevel, UserModeOperation.UNDELETE);
    return undelete(records, allOrNone);
  }

  public static SaveResult[] undelete(Collection<? extends ApexSObject> records, System.AccessLevel accessLevel) {
    return undelete(records, true, accessLevel);
  }

  public static MergeResult merge(
      ApexSObject masterRecord, ApexSObject duplicateRecord, boolean allOrNone) {
    return merge(masterRecord, List.of(duplicateRecord), allOrNone);
  }

  public static MergeResult merge(
      ApexSObject masterRecord, Collection<? extends ApexSObject> duplicateRecords, boolean allOrNone) {
    return ApexStore.merge(masterRecord, toApexSObjectCollection(duplicateRecords), allOrNone);
  }

  public static Savepoint setSavepoint() {
    return new Savepoint(ApexStore.setSavepoint());
  }

  public static void rollback(Savepoint savepoint) {
    if (savepoint == null) {
      throw new IllegalArgumentException("savepoint cannot be null");
    }
    ApexStore.rollback(savepoint.token);
  }

  public static void rollback(System.SavePoint savePoint) {
    if (savePoint == null) {
      throw new IllegalArgumentException("savepoint cannot be null");
    }
    rollback(savePoint.asDatabaseSavepoint());
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  public static List query(String soql) {
    return ApexStore.query(soql);
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  public static List Query(String soql) {
    return query(soql);
  }

  @SuppressWarnings("unchecked")
  public static <T> T query(String soql, System.AccessLevel accessLevel) {
    enforceUserModeQueryAccess(soql, accessLevel);
    return (T) query(soql);
  }

  public static int countQuery(String soql) {
    return ApexStore.countQuery(soql);
  }

  @SuppressWarnings({"unchecked"})
  public static <T> T queryWithBinds(String soql, Map<String, Object> bindVariables) {
    return (T) ApexStore.queryWithBinds(soql, bindVariables);
  }

  @SuppressWarnings({"unchecked"})
  public static <T> T queryWithBinds(
      String soql, Map<String, Object> bindVariables, System.AccessLevel accessLevel) {
    enforceUserModeQueryAccess(soql, accessLevel);
    return queryWithBinds(soql, bindVariables);
  }

  public static int countQueryWithBinds(String soql, Map<String, Object> bindVariables) {
    return ApexStore.countQueryWithBinds(soql, bindVariables);
  }

  public static List<List<ApexSObject>> search(String sosl) {
    return ApexStore.search(sosl);
  }

  public static List<List<ApexSObject>> searchWithBinds(
      String sosl, Map<String, Object> bindVariables) {
    return ApexStore.searchWithBinds(sosl, bindVariables);
  }

  public static QueryLocator getQueryLocator(String soql) {
    return new QueryLocator(query(soql), soql);
  }

  public static QueryLocator getQueryLocatorWithBinds(
      String soql, Map<String, Object> bindVariables) {
    return new QueryLocator((List<ApexSObject>) queryWithBinds(soql, bindVariables), soql);
  }

  public static void clearInMemoryStore() {
    ApexStore.reset();
  }

  public static void clearSchemaRegistry() {
    Schema.clear();
  }

  public static void clearTriggerHandlers() {
    Trigger.clearHandlers();
  }

  public static void setSoqlNullOrderDefault(NullOrderDefault mode) {
    ApexStore.setSoqlNullOrderDefault(mode);
  }

  public static NullOrderDefault getSoqlNullOrderDefault() {
    return ApexStore.getSoqlNullOrderDefault();
  }

  private enum UserModeOperation {
    CREATE,
    READ,
    UPDATE,
    UPSERT,
    DELETE,
    UNDELETE
  }

  private static void enforceUserModeDmlAccess(
      Collection<? extends ApexSObject> records,
      System.AccessLevel accessLevel,
      UserModeOperation operation) {
    if (accessLevel != System.AccessLevel.USER_MODE || records == null || records.isEmpty()) {
      return;
    }
    String objectType = firstObjectType(records);
    if (objectType == null || objectType.isBlank()) {
      return;
    }
    Schema.DescribeSObjectResult describe = new Schema.DescribeSObjectResult(objectType);
    boolean allowed =
        switch (operation) {
          case CREATE -> describe.isCreateable();
          case READ -> describe.isAccessible();
          case UPDATE -> describe.isUpdateable();
          case UPSERT -> describe.isCreateable() && describe.isUpdateable();
          case DELETE, UNDELETE -> describe.isDeletable();
        };
    if (!allowed) {
      throw new System.SecurityException("Access to entity '" + objectType + "' denied");
    }
  }

  private static String firstObjectType(Collection<? extends ApexSObject> records) {
    if (records == null || records.isEmpty()) {
      return null;
    }
    for (ApexSObject record : records) {
      if (record != null && record.type() != null && !record.type().isBlank()) {
        return record.type();
      }
    }
    return null;
  }

  private static Collection<ApexSObject> toApexSObjectCollection(
      Collection<? extends ApexSObject> records) {
    if (records == null || records.isEmpty()) {
      return List.of();
    }
    return new ArrayList<>(records);
  }

  private static void enforceUserModeQueryAccess(String soql, System.AccessLevel accessLevel) {
    if (accessLevel != System.AccessLevel.USER_MODE) {
      return;
    }
    String objectType = extractObjectTypeFromSoql(soql);
    if (objectType == null || objectType.isBlank()) {
      return;
    }
    Schema.DescribeSObjectResult describe = new Schema.DescribeSObjectResult(objectType);
    if (!describe.isAccessible()) {
      throw new QueryException(
          "Implementation restriction: sObject type '" + objectType + "' is not supported");
    }
  }

  private static String extractObjectTypeFromSoql(String soql) {
    if (soql == null || soql.isBlank()) {
      return null;
    }
    String normalized = soql.trim();
    if (normalized.startsWith("[") && normalized.endsWith("]") && normalized.length() > 1) {
      normalized = normalized.substring(1, normalized.length() - 1).trim();
    }
    String upper = normalized.toUpperCase(Locale.ROOT);
    int fromIndex = upper.indexOf(" FROM ");
    if (fromIndex < 0) {
      return null;
    }
    String afterFrom = normalized.substring(fromIndex + 6).trim();
    if (afterFrom.isEmpty()) {
      return null;
    }
    int end = 0;
    while (end < afterFrom.length()) {
      char ch = afterFrom.charAt(end);
      if (Character.isLetterOrDigit(ch) || ch == '_') {
        end += 1;
        continue;
      }
      break;
    }
    if (end <= 0) {
      return null;
    }
    return afterFrom.substring(0, end);
  }

  private static ApexSObject asSObject(Object record) {
    if (record == null) {
      return null;
    }
    if (record instanceof ApexSObject sObject) {
      return sObject;
    }
    return ApexSObject.of(record.getClass().getSimpleName());
  }

  private static List<SaveResult> toSaveResultList(SaveResult[] results) {
    List<SaveResult> out = new ArrayList<>();
    if (results == null || results.length == 0) {
      return out;
    }
    for (SaveResult result : results) {
      out.add(result);
    }
    return out;
  }

  private static List<UpsertResult> toUpsertResultList(SaveResult[] results) {
    List<UpsertResult> out = new ArrayList<>();
    if (results == null || results.length == 0) {
      return out;
    }
    for (SaveResult result : results) {
      out.add(toUpsertResult(result));
    }
    return out;
  }

  private static UpsertResult toUpsertResult(SaveResult result) {
    if (result == null) {
      return null;
    }
    return new UpsertResult(
        result.isSuccess(), result.getId(), result.getErrors(), result.isCreated());
  }

  private static List<DeleteResult> toDeleteResultList(SaveResult[] results) {
    List<DeleteResult> out = new ArrayList<>();
    if (results == null || results.length == 0) {
      return out;
    }
    for (SaveResult result : results) {
      if (result == null) {
        out.add(null);
      } else {
        out.add(new DeleteResult(result.isSuccess(), result.getId(), result.getErrors()));
      }
    }
    return out;
  }

  private static UndeleteResult toUndeleteResult(SaveResult result) {
    if (result == null) {
      return null;
    }
    return new UndeleteResult(result.isSuccess(), result.getId(), result.getErrors());
  }

  private static List<UndeleteResult> toUndeleteResultList(SaveResult[] results) {
    List<UndeleteResult> out = new ArrayList<>();
    if (results == null || results.length == 0) {
      return out;
    }
    for (SaveResult result : results) {
      out.add(toUndeleteResult(result));
    }
    return out;
  }

  private static void ensureSuccess(SaveResult[] results, String operation) {
    if (results == null) {
      return;
    }
    for (SaveResult result : results) {
      if (result == null || result.isSuccess()) {
        continue;
      }
      String message = "unknown failure";
      String statusCode = "DML_ERROR";
      Error[] errors = result.getErrors();
      if (errors.length > 0 && errors[0] != null) {
        if (errors[0].getMessage() != null) {
          message = errors[0].getMessage();
        }
        if (errors[0].getStatusCode() != null && !errors[0].getStatusCode().isBlank()) {
          statusCode = errors[0].getStatusCode();
        }
      }
      throw new apexemu.runtime.System.DmlException(
          operation + " failed: " + statusCode + ": " + message);
    }
  }

  private static void ensureSuccess(SaveResult result, String operation) {
    if (result == null) {
      return;
    }
    ensureSuccess(new SaveResult[] {result}, operation);
  }

  public static final class Savepoint {
    final long token;

    Savepoint(long token) {
      this.token = token;
    }
  }

  public static class DmlOptions {
    public static final class DuplicateRuleHeaderOptions {
      public Boolean allowSave;
      public Boolean AllowSave;

      public Boolean getAllowSave() {
        if (allowSave != null) {
          return allowSave;
        }
        return AllowSave;
      }

      public void setAllowSave(Boolean value) {
        this.allowSave = value;
        this.AllowSave = value;
      }
    }

    public Boolean OptAllOrNone;
    public Boolean optAllOrNone;
    public Boolean AllowFieldTruncation;
    public ApexSObject DuplicateRuleHeader;
    public DuplicateRuleHeaderOptions duplicateRuleHeader;

    public DmlOptions() {
      this.DuplicateRuleHeader = ApexSObject.of("DuplicateRuleHeader");
      this.duplicateRuleHeader = new DuplicateRuleHeaderOptions();
    }

    public Boolean getOptAllOrNone() {
      if (optAllOrNone != null) {
        return optAllOrNone;
      }
      return OptAllOrNone;
    }

    public void setOptAllOrNone(Boolean value) {
      this.OptAllOrNone = value;
      this.optAllOrNone = value;
    }

    @SuppressWarnings("unchecked")
    public <T> T getAs(String field) {
      if (field == null) {
        return null;
      }
      if (field.equalsIgnoreCase("OptAllOrNone") || field.equalsIgnoreCase("optAllOrNone")) {
        return (T) getOptAllOrNone();
      }
      if (field.equalsIgnoreCase("AllowFieldTruncation")) {
        return (T) AllowFieldTruncation;
      }
      if (field.equalsIgnoreCase("DuplicateRuleHeader") || field.equalsIgnoreCase("duplicateRuleHeader")) {
        syncDuplicateRuleHeaderAliasToSObject();
        return (T) ensureDuplicateRuleHeaderSObject();
      }
      return null;
    }

    public DmlOptions set(String field, Object value) {
      if (field == null) {
        return this;
      }
      if (field.equalsIgnoreCase("OptAllOrNone") || field.equalsIgnoreCase("optAllOrNone")) {
        if (value == null || value instanceof Boolean) {
          setOptAllOrNone((Boolean) value);
        } else {
          setOptAllOrNone(Boolean.valueOf(String.valueOf(value)));
        }
        return this;
      }
      if (field.equalsIgnoreCase("AllowFieldTruncation")) {
        if (value == null || value instanceof Boolean) {
          AllowFieldTruncation = (Boolean) value;
        } else {
          AllowFieldTruncation = Boolean.valueOf(String.valueOf(value));
        }
        return this;
      }
      if (field.equalsIgnoreCase("DuplicateRuleHeader") || field.equalsIgnoreCase("duplicateRuleHeader")) {
        if (value instanceof ApexSObject sObject) {
          DuplicateRuleHeader = sObject;
          syncDuplicateRuleHeaderSObjectToAlias();
        } else if (value instanceof DuplicateRuleHeaderOptions options) {
          duplicateRuleHeader = options;
          syncDuplicateRuleHeaderAliasToSObject();
        } else if (value == null) {
          DuplicateRuleHeader = ApexSObject.of("DuplicateRuleHeader");
          duplicateRuleHeader = new DuplicateRuleHeaderOptions();
        }
      }
      return this;
    }

    private ApexSObject ensureDuplicateRuleHeaderSObject() {
      if (DuplicateRuleHeader == null) {
        DuplicateRuleHeader = ApexSObject.of("DuplicateRuleHeader");
      }
      return DuplicateRuleHeader;
    }

    private void syncDuplicateRuleHeaderAliasToSObject() {
      if (duplicateRuleHeader == null) {
        return;
      }
      Boolean allowSave = duplicateRuleHeader.getAllowSave();
      if (allowSave != null) {
        ensureDuplicateRuleHeaderSObject().set("AllowSave", allowSave);
      }
    }

    @SuppressWarnings("unchecked")
    private void syncDuplicateRuleHeaderSObjectToAlias() {
      if (duplicateRuleHeader == null) {
        duplicateRuleHeader = new DuplicateRuleHeaderOptions();
      }
      Boolean allowSave = (Boolean) ensureDuplicateRuleHeaderSObject().getAs("AllowSave");
      if (allowSave != null) {
        duplicateRuleHeader.setAllowSave(allowSave);
      }
    }
  }

  public interface BatchableContext {
    String getJobId();
  }

  public static final class DefaultBatchableContext implements BatchableContext {
    private final String jobId;

    public DefaultBatchableContext(String jobId) {
      this.jobId = jobId == null ? "" : jobId;
    }

    @Override
    public String getJobId() {
      return jobId;
    }
  }

  public interface QueryLocatorIterator extends System.Iterator<ApexSObject> {}

  public static final class QueryLocator implements Iterable<ApexSObject> {
    private final List<ApexSObject> rows;
    private final String query;

    QueryLocator(List<ApexSObject> rows) {
      this(rows, null);
    }

    QueryLocator(List<ApexSObject> rows, String query) {
      this.rows = copyRows(rows);
      this.query = query;
    }

    public int size() {
      return rows.size();
    }

    public List<ApexSObject> getRecords() {
      return copyRows(rows);
    }

    public String getQuery() {
      return query;
    }

    @Override
    public QueryLocatorIterator iterator() {
      Iterator<ApexSObject> delegate = getRecords().iterator();
      return new QueryLocatorIterator() {
        @Override
        public boolean hasNext() {
          return delegate.hasNext();
        }

        @Override
        public ApexSObject next() {
          return delegate.next();
        }

        @Override
        public void remove() {
          delegate.remove();
        }
      };
    }

    private static List<ApexSObject> copyRows(List<ApexSObject> input) {
      if (input == null || input.isEmpty()) {
        return List.of();
      }
      List<ApexSObject> out = new ArrayList<>(input.size());
      for (ApexSObject row : input) {
        out.add(row == null ? null : row.copy());
      }
      return out;
    }
  }

  public enum NullOrderDefault {
    FIRST,
    LAST,
    DIRECTIONAL
  }

  public static class SaveResult {
    public final boolean success;
    public final String id;
    public final Error[] errors;
    public final boolean created;

    SaveResult(boolean success, String id, Error[] errors) {
      this(success, id, errors, false);
    }

    SaveResult(boolean success, String id, Error[] errors, boolean created) {
      this.success = success;
      this.id = id;
      this.errors = errors == null ? new Error[0] : errors.clone();
      this.created = created;
    }

    public boolean isSuccess() {
      return success;
    }

    public String getId() {
      return id;
    }

    public String getID() {
      return getId();
    }

    public Error[] getErrors() {
      return errors.clone();
    }

    public boolean isCreated() {
      return created;
    }

    @SuppressWarnings("unchecked")
    public <T> T getAs(String field) {
      if (field == null) {
        return null;
      }
      if (field.equalsIgnoreCase("id")) {
        return (T) id;
      }
      if (field.equalsIgnoreCase("success")) {
        return (T) Boolean.valueOf(success);
      }
      if (field.equalsIgnoreCase("errors")) {
        return (T) getErrors();
      }
      if (field.equalsIgnoreCase("created")) {
        return (T) Boolean.valueOf(created);
      }
      return null;
    }
  }

  public static final class UpsertResult extends SaveResult {
    public final boolean created;

    UpsertResult(boolean success, String id, Error[] errors, boolean created) {
      super(success, id, errors);
      this.created = created;
    }

    public boolean isCreated() {
      return created;
    }
  }

  public static final class DeleteResult extends SaveResult {
    DeleteResult(boolean success, String id, Error[] errors) {
      super(success, id, errors);
    }
  }

  public static final class UndeleteResult extends SaveResult {
    public UndeleteResult() {
      this(false, null, new Error[0]);
    }

    public UndeleteResult(boolean success, String id, Error[] errors) {
      super(success, id, errors);
    }
  }

  public static final class EmptyRecycleBinResult extends SaveResult {
    EmptyRecycleBinResult(boolean success, String id, Error[] errors) {
      super(success, id, errors);
    }
  }

  public static final class LeadConvertResult extends SaveResult {
    private final String leadId;
    private final String contactId;
    private final String accountId;
    private final String opportunityId;

    public LeadConvertResult() {
      this(false, null, new Error[0], null, null, null, null);
    }

    public LeadConvertResult(boolean success, String id, Error[] errors, String leadId) {
      this(success, id, errors, leadId, id, null, null);
    }

    public LeadConvertResult(
        boolean success,
        String id,
        Error[] errors,
        String leadId,
        String contactId,
        String accountId,
        String opportunityId) {
      super(success, id, errors);
      this.leadId = leadId;
      this.contactId = contactId;
      this.accountId = accountId;
      this.opportunityId = opportunityId;
    }

    public String getLeadId() {
      return leadId;
    }

    public String getContactId() {
      return contactId;
    }

    public String getAccountId() {
      return accountId;
    }

    public String getOpportunityId() {
      return opportunityId;
    }
  }

  public static final class LeadConvert {
    private String leadId;
    private String opportunityName;
    private boolean doNotCreateOpportunity;
    private String convertedStatus;
    private String ownerId;
    private boolean sendNotificationEmail;
    private String contactId;
    private String accountId;

    public String getLeadId() {
      return leadId;
    }

    public void setLeadId(String leadId) {
      this.leadId = leadId;
    }

    public String getOpportunityName() {
      return opportunityName;
    }

    public void setOpportunityName(String opportunityName) {
      this.opportunityName = opportunityName;
    }

    public boolean isDoNotCreateOpportunity() {
      return doNotCreateOpportunity;
    }

    public void setDoNotCreateOpportunity(boolean doNotCreateOpportunity) {
      this.doNotCreateOpportunity = doNotCreateOpportunity;
    }

    public String getConvertedStatus() {
      return convertedStatus;
    }

    public void setConvertedStatus(String convertedStatus) {
      this.convertedStatus = convertedStatus;
    }

    public String getOwnerId() {
      return ownerId;
    }

    public void setOwnerId(String ownerId) {
      this.ownerId = ownerId;
    }

    public boolean isSendNotificationEmail() {
      return sendNotificationEmail;
    }

    public void setSendNotificationEmail(boolean sendNotificationEmail) {
      this.sendNotificationEmail = sendNotificationEmail;
    }

    public String getContactId() {
      return contactId;
    }

    public void setContactId(String contactId) {
      this.contactId = contactId;
    }

    public String getAccountId() {
      return accountId;
    }

    public void setAccountId(String accountId) {
      this.accountId = accountId;
    }
  }

  public static final class MergeResult extends SaveResult {
    private final String[] mergedRecordIds;
    private final String[] updatedRelatedIds;

    MergeResult(
        boolean success,
        String id,
        Error[] errors,
        String[] mergedRecordIds,
        String[] updatedRelatedIds) {
      super(success, id, errors);
      this.mergedRecordIds = mergedRecordIds == null ? new String[0] : mergedRecordIds.clone();
      this.updatedRelatedIds = updatedRelatedIds == null ? new String[0] : updatedRelatedIds.clone();
    }

    public String[] getMergedRecordIds() {
      return mergedRecordIds.clone();
    }

    public String[] getUpdatedRelatedIds() {
      return updatedRelatedIds.clone();
    }
  }

  public enum StatusCode {
    FIELD_CUSTOM_VALIDATION_EXCEPTION,
    REQUIRED_FIELD_MISSING,
    DUPLICATES_DETECTED
  }

  public static class Error {
    private final String statusCode;
    private final String message;
    private final String[] fields;

    Error(String statusCode, String message) {
      this(statusCode, message, new String[0]);
    }

    Error(String statusCode, String message, String[] fields) {
      this.statusCode = statusCode;
      this.message = message == null ? "" : message;
      this.fields = fields == null ? new String[0] : fields.clone();
    }

    public String getStatusCode() {
      return statusCode;
    }

    public String getMessage() {
      return message;
    }

    public String[] getFields() {
      return fields.clone();
    }
  }

  public static final class DuplicateError extends Error {
    private final Datacloud.DuplicateResult duplicateResult;

    public DuplicateError(String statusCode, String message, Datacloud.DuplicateResult duplicateResult) {
      super(statusCode, message);
      this.duplicateResult = duplicateResult == null ? new Datacloud.DuplicateResult() : duplicateResult;
    }

    public Datacloud.DuplicateResult getDuplicateResult() {
      return duplicateResult;
    }
  }
}
