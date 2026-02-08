package apexemu.runtime;

import java.util.Collection;
import java.util.List;

public final class Database {
  private Database() {}

  public static String executeBatch(Batchable job) {
    return executeBatch(job, 200);
  }

  public static String executeBatch(Batchable job, int scopeSize) {
    return Async.enqueueBatch(job, scopeSize);
  }

  public static void insert(Collection<ApexSObject> records) {
    ensureSuccess(insert(records, true), "insert");
  }

  public static void update(Collection<ApexSObject> records) {
    ensureSuccess(update(records, true), "update");
  }

  public static void upsert(Collection<ApexSObject> records) {
    ensureSuccess(upsert(records, true), "upsert");
  }

  public static void delete(Collection<ApexSObject> records) {
    ensureSuccess(delete(records, true), "delete");
  }

  public static void undelete(Collection<ApexSObject> records) {
    ensureSuccess(undelete(records, true), "undelete");
  }

  public static SaveResult[] insert(Collection<ApexSObject> records, boolean allOrNone) {
    return ApexStore.insert(records, allOrNone);
  }

  public static SaveResult[] update(Collection<ApexSObject> records, boolean allOrNone) {
    return ApexStore.update(records, allOrNone);
  }

  public static SaveResult[] upsert(Collection<ApexSObject> records, boolean allOrNone) {
    return ApexStore.upsert(records, allOrNone);
  }

  public static SaveResult[] delete(Collection<ApexSObject> records, boolean allOrNone) {
    return ApexStore.delete(records, allOrNone);
  }

  public static SaveResult[] undelete(Collection<ApexSObject> records, boolean allOrNone) {
    return ApexStore.undelete(records, allOrNone);
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

  public static List<ApexSObject> query(String soql) {
    return ApexStore.query(soql);
  }

  public static int countQuery(String soql) {
    return ApexStore.countQuery(soql);
  }

  public static void clearInMemoryStore() {
    ApexStore.reset();
  }

  public static void clearSchemaRegistry() {
    Schema.clear();
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
      Error[] errors = result.getErrors();
      if (errors.length > 0 && errors[0] != null && errors[0].getMessage() != null) {
        message = errors[0].getMessage();
      }
      throw new IllegalArgumentException(operation + " failed: " + message);
    }
  }

  public static final class Savepoint {
    final long token;

    Savepoint(long token) {
      this.token = token;
    }
  }

  public static final class SaveResult {
    private final boolean success;
    private final String id;
    private final Error[] errors;

    SaveResult(boolean success, String id, Error[] errors) {
      this.success = success;
      this.id = id;
      this.errors = errors == null ? new Error[0] : errors.clone();
    }

    public boolean isSuccess() {
      return success;
    }

    public String getId() {
      return id;
    }

    public Error[] getErrors() {
      return errors.clone();
    }
  }

  public static final class Error {
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
}
