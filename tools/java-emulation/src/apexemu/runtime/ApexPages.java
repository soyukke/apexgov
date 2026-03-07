package apexemu.runtime;

public final class ApexPages {
  private static final ThreadLocal<PageReference> CURRENT_PAGE =
      ThreadLocal.withInitial(() -> new PageReference(""));
  private static final ThreadLocal<java.util.List<Message>> MESSAGES =
      ThreadLocal.withInitial(java.util.ArrayList::new);

  private ApexPages() {}

  public static PageReference currentPage() {
    return CURRENT_PAGE.get();
  }

  public enum Severity {
    INFO,
    WARNING,
    ERROR
  }

  public static final class Message {
    private final Severity severity;
    private final String summary;

    public Message(Severity severity, String summary) {
      this.severity = severity == null ? Severity.INFO : severity;
      this.summary = summary == null ? "" : summary;
    }

    public Severity getSeverity() {
      return severity;
    }

    public String getSummary() {
      return summary;
    }
  }

  static void setCurrentPage(PageReference pageReference) {
    CURRENT_PAGE.set(pageReference == null ? new PageReference("") : pageReference);
  }

  public static void addMessage(Message message) {
    if (message != null) {
      MESSAGES.get().add(message);
    }
  }

  public static void addMessages(Exception error) {
    if (error == null) {
      return;
    }
    addMessage(new Message(Severity.ERROR, error.getMessage()));
  }

  public static boolean hasMessages() {
    return !MESSAGES.get().isEmpty();
  }

  public static java.util.List<Message> getMessages() {
    return new java.util.ArrayList<>(MESSAGES.get());
  }

  public static final class StandardController {
    private final ApexSObject record;

    public StandardController(ApexSObject record) {
      this.record = record;
    }

    public ApexSObject getRecord() {
      return record;
    }

    public String getId() {
      return record == null ? null : record.id();
    }

    public PageReference view() {
      return new PageReference("");
    }
  }

  public static final class StandardSetController {
    private final java.util.List<ApexSObject> records;

    public StandardSetController(java.util.List<ApexSObject> records) {
      this.records =
          records == null ? java.util.List.of() : new java.util.ArrayList<>(records);
    }

    public java.util.List<ApexSObject> getRecords() {
      return new java.util.ArrayList<>(records);
    }

    public java.util.List<ApexSObject> getSelected() {
      return getRecords();
    }
  }
}
