package apexemu.runtime;

public final class Approval {
  private Approval() {}

  public static final class LockResult {
    public String id;
    public final boolean success;

    public LockResult() {
      this(true);
    }

    public LockResult(boolean success) {
      this.success = success;
    }

    public boolean isSuccess() {
      return success;
    }

    public String getId() {
      return id;
    }
  }

  public static final class UnlockResult {
    public String id;
    public final boolean success;

    public UnlockResult() {
      this(true);
    }

    public UnlockResult(boolean success) {
      this.success = success;
    }

    public boolean isSuccess() {
      return success;
    }

    public String getId() {
      return id;
    }
  }

  public static final class ProcessResult {
    public String entityId;
    public final boolean success;

    public ProcessResult() {
      this(true);
    }

    public ProcessResult(boolean success) {
      this.success = success;
    }

    public boolean isSuccess() {
      return success;
    }

    public String getEntityId() {
      return entityId;
    }
  }
}
