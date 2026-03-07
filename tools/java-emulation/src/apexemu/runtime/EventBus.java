package apexemu.runtime;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class EventBus {
  private static final ThreadLocal<State> STATE = ThreadLocal.withInitial(State::new);

  private EventBus() {}

  public interface EventPublishSuccessCallback {
    default void onSuccess(SuccessResult result) {}
  }

  public interface EventPublishFailureCallback {
    default void onFailure(FailureResult result) {}
  }

  static void resetForTestWindow() {
    STATE.set(new State());
  }

  static void forceFailure() {
    STATE.get().forceFailure = true;
  }

  static void forceDelivery() {
    STATE.get().forceFailure = false;
    flushPending();
  }

  static void flushPending() {
    State state = STATE.get();
    if (state.pending.isEmpty()) {
      state.forceFailure = false;
      return;
    }

    List<PendingPublish> batches = new ArrayList<>(state.pending);
    state.pending.clear();
    boolean forceFailure = state.forceFailure;
    state.forceFailure = false;

    for (PendingPublish batch : batches) {
      if (batch == null) {
        continue;
      }
      boolean callbackShouldFail = forceFailure || !batch.publishAccepted;

      if (!callbackShouldFail && !batch.successfulEvents.isEmpty()) {
        dispatchPublishedEvents(batch.successfulEvents);
      }

      if (batch.callback != null) {
        if (callbackShouldFail) {
          tryInvoke(
              batch.callback,
              "onFailure",
              FailureResult.class,
              new FailureResult(batch.callbackEventUuids));
        } else {
          tryInvoke(
              batch.callback,
              "onSuccess",
              SuccessResult.class,
              new SuccessResult(batch.callbackEventUuids));
        }
      }
    }
  }

  public static Database.SaveResult publish(ApexSObject event) {
    if (event == null) {
      return null;
    }
    List<Database.SaveResult> results = publishInternal(List.of(event), null);
    return results.isEmpty() ? null : results.get(0);
  }

  public static Database.SaveResult publish(ApexSObject event, Object callback) {
    if (event == null) {
      return null;
    }
    List<Database.SaveResult> results = publishInternal(List.of(event), callback);
    return results.isEmpty() ? null : results.get(0);
  }

  public static List<Database.SaveResult> publish(List<ApexSObject> events) {
    return publishInternal(events, null);
  }

  public static List<Database.SaveResult> publish(List<ApexSObject> events, Object callback) {
    return publishInternal(events, callback);
  }

  private static List<Database.SaveResult> publishInternal(List<ApexSObject> events, Object callback) {
    if (events == null || events.isEmpty()) {
      return List.of();
    }

    List<ApexSObject> rows = new ArrayList<>();
    for (ApexSObject row : events) {
      if (row != null) {
        applyEventDefaults(row);
        rows.add(row);
      }
    }
    if (rows.isEmpty()) {
      return List.of();
    }

    List<Database.SaveResult> results = Database.insert(rows, false);
    List<Database.SaveResult> safeResults =
        results == null ? List.of() : new ArrayList<>(results);

    List<ApexSObject> successfulEvents = new ArrayList<>();
    List<String> callbackEventUuids = new ArrayList<>();
    boolean publishAccepted = true;

    int limit = Math.min(rows.size(), safeResults.size());
    for (int i = 0; i < limit; i += 1) {
      ApexSObject event = rows.get(i);
      Database.SaveResult result = safeResults.get(i);
      if (result == null || !result.isSuccess()) {
        publishAccepted = false;
        continue;
      }

      successfulEvents.add(event.copy());
      String eventUuid = eventUuidForCallback(event, result);
      if (eventUuid != null && !eventUuid.isBlank()) {
        callbackEventUuids.add(eventUuid);
      }
    }

    for (int i = limit; i < rows.size(); i += 1) {
      publishAccepted = false;
    }

    STATE
        .get()
        .pending
        .add(new PendingPublish(successfulEvents, callback, callbackEventUuids, publishAccepted));

    return safeResults;
  }

  private static String eventUuidForCallback(ApexSObject event, Database.SaveResult result) {
    if (event != null) {
      Object explicit = event.get("EventUuid");
      if (explicit == null) {
        explicit = event.get("eventuuid");
      }
      if (explicit != null) {
        String value = String.valueOf(explicit).trim();
        if (!value.isEmpty()) {
          return value;
        }
      }
    }
    if (result != null && result.getId() != null && !result.getId().isBlank()) {
      return result.getId();
    }
    return null;
  }

  private static void applyEventDefaults(ApexSObject event) {
    if (event == null || event.type() == null) {
      return;
    }
    if (event.type().equalsIgnoreCase("Log__e")) {
      if (event.get("Request_Id__c") == null) {
        event.set("Request_Id__c", System.Request.getCurrent().getRequestId());
      }
      if (event.get("Quiddity__c") == null) {
        System.Quiddity quiddity = System.Request.getCurrent().getQuiddity();
        if (quiddity != null) {
          event.set("Quiddity__c", quiddity.name());
        }
      }
    }
  }

  private static void dispatchPublishedEvents(List<ApexSObject> events) {
    if (events == null || events.isEmpty()) {
      return;
    }

    Map<String, List<ApexSObject>> grouped = new LinkedHashMap<>();
    for (ApexSObject event : events) {
      if (event == null || event.type() == null || event.type().isBlank()) {
        continue;
      }
      grouped
          .computeIfAbsent(event.type().toLowerCase(Locale.ROOT), ignored -> new ArrayList<>())
          .add(event.copy());
    }

    for (Map.Entry<String, List<ApexSObject>> entry : grouped.entrySet()) {
      String typeLower = entry.getKey();
      List<ApexSObject> rows = entry.getValue();
      if (rows == null || rows.isEmpty()) {
        continue;
      }

      String canonicalType = rows.get(0).type();
      Trigger.dispatchAfter(canonicalType, Trigger.Operation.INSERT, rows, null);
      invokeInferredTriggerHandlers(canonicalType, rows);
    }
  }

  private static void invokeInferredTriggerHandlers(String eventType, List<ApexSObject> rows) {
    if (eventType == null || eventType.isBlank() || rows == null || rows.isEmpty()) {
      return;
    }
    String normalizedType = eventType.trim();
    if (!normalizedType.toLowerCase(Locale.ROOT).endsWith("__e")) {
      return;
    }

    List<Class<?>> candidates = resolveEventHandlerCandidates(normalizedType);
    for (Class<?> handlerClass : candidates) {
      invokeTriggerHandler(handlerClass, rows);
    }
  }

  private static List<Class<?>> resolveEventHandlerCandidates(String eventType) {
    List<Class<?>> classes = System.registeredClassesSnapshot();
    if (classes == null || classes.isEmpty()) {
      return List.of();
    }

    int bestScore = 0;
    List<Class<?>> best = new ArrayList<>();
    for (Class<?> klass : classes) {
      if (klass == null) {
        continue;
      }
      String simpleName = klass.getSimpleName();
      if (simpleName == null || !simpleName.endsWith("TriggerHandler")) {
        continue;
      }
      if (simpleName.equals("TriggerHandler") || simpleName.equals("MetadataTriggerHandler")) {
        continue;
      }
      int score = scoreEventHandlerMatch(eventType, simpleName);
      if (score <= 0) {
        continue;
      }
      if (score > bestScore) {
        bestScore = score;
        best.clear();
        best.add(klass);
      } else if (score == bestScore) {
        best.add(klass);
      }
    }

    if (bestScore <= 0) {
      return List.of();
    }

    List<Class<?>> unique = new ArrayList<>();
    LinkedHashSet<String> seen = new LinkedHashSet<>();
    for (Class<?> klass : best) {
      if (klass == null) {
        continue;
      }
      String name = klass.getName();
      if (seen.add(name)) {
        unique.add(klass);
      }
    }
    return unique;
  }

  private static int scoreEventHandlerMatch(String eventType, String handlerSimpleName) {
    if (eventType == null || handlerSimpleName == null) {
      return 0;
    }

    String eventBase = eventType;
    if (eventBase.endsWith("__e") || eventBase.endsWith("__E")) {
      eventBase = eventBase.substring(0, eventBase.length() - 3);
    }

    String eventCompact = eventBase.replaceAll("[^A-Za-z0-9]", "").toLowerCase(Locale.ROOT);
    String handlerBase =
        handlerSimpleName.substring(0, handlerSimpleName.length() - "TriggerHandler".length());
    String handlerCompact = handlerBase.replaceAll("[^A-Za-z0-9]", "").toLowerCase(Locale.ROOT);

    int score = 0;
    if (handlerCompact.equals(eventCompact)) {
      score += 40;
    }
    if (eventCompact.endsWith("event")
        && handlerCompact.equals(eventCompact.substring(0, eventCompact.length() - "event".length()))) {
      score += 30;
    }

    String[] tokens = eventBase.toLowerCase(Locale.ROOT).split("[^a-z0-9]+");
    for (String token : tokens) {
      if (token == null || token.length() <= 2) {
        continue;
      }
      if (handlerCompact.contains(token)) {
        score += 5;
      }
    }

    if (handlerCompact.contains("event") && eventCompact.contains("event")) {
      score += 2;
    }

    return score;
  }

  private static void invokeTriggerHandler(Class<?> handlerClass, List<ApexSObject> rows) {
    if (handlerClass == null || rows == null || rows.isEmpty()) {
      return;
    }

    try {
      Method runMethod = handlerClass.getMethod("run");
      Constructor<?> ctor = handlerClass.getDeclaredConstructor();
      ctor.setAccessible(true);

      List<ApexSObject> snapshot = new ArrayList<>(rows.size());
      for (ApexSObject row : rows) {
        snapshot.add(row == null ? null : row.copy());
      }

      Trigger.afterInsert(
          snapshot,
          () -> {
            try {
              Object instance = ctor.newInstance();
              runMethod.invoke(instance);
            } catch (java.lang.reflect.InvocationTargetException error) {
              Throwable cause = error.getCause();
              if (cause instanceof RuntimeException runtimeError) {
                throw runtimeError;
              }
              if (cause instanceof Error severeError) {
                throw severeError;
              }
              throw new RuntimeException(cause);
            } catch (ReflectiveOperationException error) {
              throw new RuntimeException(error);
            }
          });
    } catch (NoSuchMethodException ignored) {
      // best-effort event trigger dispatch
    }
  }

  private static void tryInvoke(Object callback, String methodName, Class<?> argType, Object arg) {
    try {
      Method method = callback.getClass().getMethod(methodName, argType);
      method.invoke(callback, arg);
    } catch (ReflectiveOperationException ignored) {
      // best-effort emulation: callback handlers are optional
    }
  }

  private static final class State {
    final List<PendingPublish> pending = new ArrayList<>();
    boolean forceFailure;
  }

  private static final class PendingPublish {
    final List<ApexSObject> successfulEvents;
    final Object callback;
    final List<String> callbackEventUuids;
    final boolean publishAccepted;

    private PendingPublish(
        List<ApexSObject> successfulEvents,
        Object callback,
        List<String> callbackEventUuids,
        boolean publishAccepted) {
      this.successfulEvents =
          successfulEvents == null ? List.of() : new ArrayList<>(successfulEvents);
      this.callback = callback;
      this.callbackEventUuids =
          callbackEventUuids == null ? List.of() : new ArrayList<>(callbackEventUuids);
      this.publishAccepted = publishAccepted;
    }
  }

  public static class ChangeEventHeader {
    public String entityName;
    public List<String> recordIds = new ArrayList<>();
    public String changeType;
    public String changeOrigin;
    public String transactionKey;
    public Integer sequenceNumber;
    public Long commitTimestamp;
    public String commitUser;
    public Long commitNumber;
    public List<String> nulledFields = new ArrayList<>();
    public List<String> diffFields = new ArrayList<>();
    public List<String> changedFields = new ArrayList<>();

    public String getEntityName() {
      return entityName;
    }

    public List<String> getRecordIds() {
      return recordIds == null ? List.of() : new ArrayList<>(recordIds);
    }

    public String getChangeType() {
      return changeType;
    }

    public String getChangeOrigin() {
      return changeOrigin;
    }

    public String getTransactionKey() {
      return transactionKey;
    }

    public Integer getSequenceNumber() {
      return sequenceNumber;
    }

    public Long getCommitTimestamp() {
      return commitTimestamp;
    }

    public String getCommitUser() {
      return commitUser;
    }

    public Long getCommitNumber() {
      return commitNumber;
    }

    public List<String> getNulledFields() {
      return nulledFields == null ? List.of() : new ArrayList<>(nulledFields);
    }

    public List<String> getDiffFields() {
      return diffFields == null ? List.of() : new ArrayList<>(diffFields);
    }

    public List<String> getChangedFields() {
      return changedFields == null ? List.of() : new ArrayList<>(changedFields);
    }
  }

  public static class SuccessResult {
    private final List<String> eventUuids;

    public SuccessResult(List<String> eventUuids) {
      this.eventUuids = eventUuids == null ? List.of() : new ArrayList<>(eventUuids);
    }

    public List<String> getEventUuids() {
      return new ArrayList<>(eventUuids);
    }
  }

  public static class FailureResult {
    private final List<String> eventUuids;

    public FailureResult(List<String> eventUuids) {
      this.eventUuids = eventUuids == null ? List.of() : new ArrayList<>(eventUuids);
    }

    public List<String> getEventUuids() {
      return new ArrayList<>(eventUuids);
    }
  }
}
