package apexemu.runtime;

public final class ApexPages {
  private static final ThreadLocal<PageReference> CURRENT_PAGE =
      ThreadLocal.withInitial(() -> new PageReference(""));
  private static final ThreadLocal<java.util.List<Message>> MESSAGES =
      ThreadLocal.withInitial(java.util.ArrayList::new);
  public static final java.util.function.Supplier<PageReference> currentPage = ApexPages::currentPage;

  private ApexPages() {}

  public static PageReference currentPage() {
    return CURRENT_PAGE.get();
  }

  public static PageReference CurrentPage() {
    return currentPage();
  }

  public enum Severity {
    INFO,
    WARNING,
    ERROR,
    CONFIRM,
    FATAL;

    public static final Severity Info = INFO;
    public static final Severity Warning = WARNING;
    public static final Severity Error = ERROR;
    public static final Severity Confirm = CONFIRM;
    public static final Severity Fatal = FATAL;
  }

  public static class Message {
    private final Severity severity;
    private final String summary;
    private final String detail;

    public Message(Severity severity, String summary) {
      this.severity = severity == null ? Severity.INFO : severity;
      this.summary = summary == null ? "" : summary;
      this.detail = this.summary;
    }

    public Message(Severity severity, String summary, String detail) {
      this.severity = severity == null ? Severity.INFO : severity;
      this.summary = summary == null ? "" : summary;
      this.detail = detail == null ? this.summary : detail;
    }

    public Severity getSeverity() {
      return severity;
    }

    public String getSummary() {
      return summary;
    }

    public String getDetail() {
      return detail;
    }

    public String getComponentLabel() {
      return summary;
    }
  }

  public static final class Action {
    private final String expression;

    public Action(String expression) {
      this.expression = expression == null ? "" : expression;
    }

    public PageReference invoke() {
      return new PageReference(expression);
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

  public static void addmessage(Message message) {
    addMessage(message);
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

  public static class StandardController {
    private final ApexSObject record;

    public StandardController(ApexSObject record) {
      this.record = record;
      ensureRecordBackedByStore(record);
    }

    public ApexSObject getRecord() {
      return record;
    }

    public String getId() {
      return record == null ? null : record.id();
    }

    public void addFields(java.util.List<String> fieldNames) {}

    public PageReference view() {
      return new PageReference("");
    }

    public PageReference save() {
      if (record != null) {
        if (record.id() != null && !record.id().isBlank()) {
          Database.update(record);
        } else {
          Database.insert(record);
        }
      }
      return new PageReference("");
    }

    private static void ensureRecordBackedByStore(ApexSObject record) {
      if (record == null || record.id() == null || record.id().isBlank()) {
        return;
      }
      try {
        java.util.Map<String, Object> bindVariables = new java.util.LinkedHashMap<>();
        bindVariables.put("controllerId", record.id());
        java.util.List<ApexSObject> existing =
            ApexStore.queryWithBinds(
                "SELECT Id FROM " + record.type() + " WHERE Id = :controllerId LIMIT 1",
                bindVariables);
        if (existing == null || existing.isEmpty()) {
          ApexStore.upsert(java.util.List.of(record), true);
        }
      } catch (RuntimeException ignored) {
        // Keep controller construction resilient even when backing-store sync cannot be applied.
      }
    }
  }

  public static class StandardSetController {
    private final java.util.List<ApexSObject> records;
    private java.util.List<ApexSObject> selected;
    private int pageNumber = 1;
    private int pageSize = 20;

    public StandardSetController(java.util.List<ApexSObject> records) {
      this.records =
          records == null ? java.util.List.of() : new java.util.ArrayList<>(records);
      this.selected = new java.util.ArrayList<>(this.records);
    }

    public java.util.List<ApexSObject> getRecords() {
      return new java.util.ArrayList<>(records);
    }

    public java.util.List<ApexSObject> getSelected() {
      return new java.util.ArrayList<>(selected);
    }

    public void setSelected(java.util.List<ApexSObject> selected) {
      this.selected =
          selected == null ? new java.util.ArrayList<>() : new java.util.ArrayList<>(selected);
    }

    public Integer getResultSize() {
      return records.size();
    }

    public Integer getPageNumber() {
      return pageNumber;
    }

    public void setPageSize(Integer pageSize) {
      if (pageSize == null || pageSize <= 0) {
        return;
      }
      this.pageSize = pageSize;
      int maxPage = Math.max(1, (int) Math.ceil((double) records.size() / Math.max(1, this.pageSize)));
      if (pageNumber > maxPage) {
        pageNumber = maxPage;
      }
    }

    public void first() {
      pageNumber = 1;
    }

    public void previous() {
      if (pageNumber > 1) {
        pageNumber -= 1;
      }
    }

    public void next() {
      int maxPage = Math.max(1, (int) Math.ceil((double) records.size() / Math.max(1, pageSize)));
      if (pageNumber < maxPage) {
        pageNumber += 1;
      }
    }

    public void last() {
      pageNumber = Math.max(1, (int) Math.ceil((double) records.size() / Math.max(1, pageSize)));
    }
  }

  public static boolean hasMessages(Severity severity) {
    if (severity == null) {
      return hasMessages();
    }
    for (Message message : MESSAGES.get()) {
      if (message.getSeverity() == severity) {
        return true;
      }
    }
    return false;
  }
}
