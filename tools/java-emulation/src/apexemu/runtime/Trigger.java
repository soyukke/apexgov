package apexemu.runtime;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class Trigger {
  private static final ThreadLocal<State> STATE = ThreadLocal.withInitial(State::new);
  private static final ThreadLocal<Registry> REGISTRY = ThreadLocal.withInitial(Registry::new);
  public static System.TriggerOperation operationType = null;

  private Trigger() {}

  public enum Operation {
    INSERT,
    UPDATE,
    DELETE,
    UNDELETE
  }

  public enum TriggerOperation {
    BEFORE_INSERT,
    BEFORE_UPDATE,
    BEFORE_DELETE,
    AFTER_INSERT,
    AFTER_UPDATE,
    AFTER_DELETE,
    AFTER_UNDELETE
  }

  public static void run(
      boolean isBefore,
      Operation operation,
      List<?> newRecords,
      List<?> oldRecords,
      Runnable handler) {
    if (operation == null) {
      throw new IllegalArgumentException("operation cannot be null");
    }
    if (handler == null) {
      throw new IllegalArgumentException("handler cannot be null");
    }

    State previous = STATE.get();
    System.TriggerOperation previousOperationType = operationType;
    State current = new State();
    current.executing = true;
    current.before = isBefore;
    current.after = !isBefore;
    current.operation = operation;
    operationType = toTriggerOperation(isBefore, operation);
    current.newRecords = toObjectList(newRecords);
    current.oldRecords = toObjectList(oldRecords);
    current.newMap = buildMap(current.newRecords);
    current.oldMap = buildMap(current.oldRecords);
    STATE.set(current);

    try {
      handler.run();
    } finally {
      STATE.set(previous);
      operationType = previousOperationType;
    }
  }

  public static void beforeInsert(List<?> newRecords, Runnable handler) {
    run(true, Operation.INSERT, newRecords, null, handler);
  }

  public static void beforeUpdate(List<?> oldRecords, List<?> newRecords, Runnable handler) {
    run(true, Operation.UPDATE, newRecords, oldRecords, handler);
  }

  public static void beforeDelete(List<?> oldRecords, Runnable handler) {
    run(true, Operation.DELETE, null, oldRecords, handler);
  }

  public static void afterInsert(List<?> newRecords, Runnable handler) {
    run(false, Operation.INSERT, newRecords, null, handler);
  }

  public static void afterUpdate(List<?> oldRecords, List<?> newRecords, Runnable handler) {
    run(false, Operation.UPDATE, newRecords, oldRecords, handler);
  }

  public static void afterDelete(List<?> oldRecords, Runnable handler) {
    run(false, Operation.DELETE, null, oldRecords, handler);
  }

  public static void afterUndelete(List<?> newRecords, Runnable handler) {
    run(false, Operation.UNDELETE, newRecords, null, handler);
  }

  public static void onBeforeInsert(String sobjectType, Runnable handler) {
    register(sobjectType, true, Operation.INSERT, handler);
  }

  public static void onBeforeUpdate(String sobjectType, Runnable handler) {
    register(sobjectType, true, Operation.UPDATE, handler);
  }

  public static void onBeforeDelete(String sobjectType, Runnable handler) {
    register(sobjectType, true, Operation.DELETE, handler);
  }

  public static void onAfterInsert(String sobjectType, Runnable handler) {
    register(sobjectType, false, Operation.INSERT, handler);
  }

  public static void onAfterUpdate(String sobjectType, Runnable handler) {
    register(sobjectType, false, Operation.UPDATE, handler);
  }

  public static void onAfterDelete(String sobjectType, Runnable handler) {
    register(sobjectType, false, Operation.DELETE, handler);
  }

  public static void onAfterUndelete(String sobjectType, Runnable handler) {
    register(sobjectType, false, Operation.UNDELETE, handler);
  }

  public static void clearHandlers() {
    REGISTRY.set(new Registry());
  }

  public static void setContext(
      boolean isBefore, Operation operation, List<?> newRecords, List<?> oldRecords) {
    State current = new State();
    current.executing = true;
    current.before = isBefore;
    current.after = !isBefore;
    current.operation = operation;
    operationType = toTriggerOperation(isBefore, operation);
    current.newRecords = toObjectList(newRecords);
    current.oldRecords = toObjectList(oldRecords);
    current.newMap = buildMap(current.newRecords);
    current.oldMap = buildMap(current.oldRecords);
    STATE.set(current);
  }

  public static void setTriggerContext(String context, Boolean isBefore) {
    if (context == null || context.isBlank()) {
      clearContext();
      return;
    }
    String normalized = context.trim().toUpperCase();
    Operation op = switch (normalized) {
      case "INSERT" -> Operation.INSERT;
      case "UPDATE" -> Operation.UPDATE;
      case "DELETE" -> Operation.DELETE;
      case "UNDELETE" -> Operation.UNDELETE;
      default -> null;
    };
    if (op == null) {
      clearContext();
      return;
    }
    boolean before = isBefore != null && isBefore;
    setContext(before, op, new ArrayList<>(), new ArrayList<>());
  }

  public static void clearContext() {
    STATE.set(new State());
    operationType = null;
  }

  public static boolean isExecuting() {
    return STATE.get().executing;
  }

  public static boolean isBefore() {
    return STATE.get().before;
  }

  public static boolean isAfter() {
    return STATE.get().after;
  }

  public static boolean isInsert() {
    return STATE.get().operation == Operation.INSERT;
  }

  public static boolean isUpdate() {
    return STATE.get().operation == Operation.UPDATE;
  }

  public static boolean isDelete() {
    return STATE.get().operation == Operation.DELETE;
  }

  public static boolean isUndelete() {
    return STATE.get().operation == Operation.UNDELETE;
  }

  public static System.TriggerOperation getOperationType() {
    return operationType;
  }

  private static System.TriggerOperation toTriggerOperation(boolean isBefore, Operation operation) {
    if (operation == null) {
      return null;
    }
    if (isBefore) {
      return switch (operation) {
        case INSERT -> System.TriggerOperation.BEFORE_INSERT;
        case UPDATE -> System.TriggerOperation.BEFORE_UPDATE;
        case DELETE -> System.TriggerOperation.BEFORE_DELETE;
        case UNDELETE -> null;
      };
    }
    return switch (operation) {
      case INSERT -> System.TriggerOperation.AFTER_INSERT;
      case UPDATE -> System.TriggerOperation.AFTER_UPDATE;
      case DELETE -> System.TriggerOperation.AFTER_DELETE;
      case UNDELETE -> System.TriggerOperation.AFTER_UNDELETE;
    };
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  public static List getNew() {
    State state = STATE.get();
    if (state == null || state.newRecords == null || state.newRecords.isEmpty()) {
      return null;
    }
    return (List) state.newRecords;
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  public static List getOld() {
    State state = STATE.get();
    if (state == null || state.oldRecords == null || state.oldRecords.isEmpty()) {
      return null;
    }
    return (List) state.oldRecords;
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  public static Map getNewMap() {
    return (Map) STATE.get().newMap;
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  public static Map getOldMap() {
    return (Map) STATE.get().oldMap;
  }

  public static int size() {
    State state = STATE.get();
    if (!state.newRecords.isEmpty()) {
      return state.newRecords.size();
    }
    return state.oldRecords.size();
  }

  static void dispatchBefore(
      String sobjectType, Operation operation, List<?> newRecords, List<?> oldRecords) {
    if (operation == null || operation == Operation.UNDELETE) {
      return;
    }
    dispatch(sobjectType, true, operation, newRecords, oldRecords);
  }

  static void dispatchAfter(
      String sobjectType, Operation operation, List<?> newRecords, List<?> oldRecords) {
    if (operation == null) {
      return;
    }
    dispatch(sobjectType, false, operation, newRecords, oldRecords);
  }

  private static void dispatch(
      String sobjectType, boolean isBefore, Operation operation, List<?> newRecords, List<?> oldRecords) {
    String normalizedType = normalizeType(sobjectType);
    if (normalizedType == null) {
      return;
    }

    HandlerKey key = new HandlerKey(normalizedType, isBefore, operation);
    List<Runnable> handlers = REGISTRY.get().handlers.get(key);
    if (handlers == null || handlers.isEmpty()) {
      return;
    }

    List<Runnable> snapshot = new ArrayList<>(handlers);
    for (Runnable handler : snapshot) {
      run(isBefore, operation, newRecords, oldRecords, handler);
    }
  }

  private static void register(
      String sobjectType, boolean isBefore, Operation operation, Runnable handler) {
    if (operation == null) {
      throw new IllegalArgumentException("operation cannot be null");
    }
    if (handler == null) {
      throw new IllegalArgumentException("handler cannot be null");
    }
    String normalizedType = normalizeType(sobjectType);
    if (normalizedType == null) {
      throw new IllegalArgumentException("sobjectType cannot be blank");
    }

    HandlerKey key = new HandlerKey(normalizedType, isBefore, operation);
    REGISTRY.get().handlers.computeIfAbsent(key, ignored -> new ArrayList<>()).add(handler);
  }

  private static String normalizeType(String sobjectType) {
    if (sobjectType == null || sobjectType.isBlank()) {
      return null;
    }
    return sobjectType.trim().toLowerCase();
  }

  private static List<Object> toObjectList(List<?> raw) {
    if (raw == null || raw.isEmpty()) {
      return Collections.emptyList();
    }
    return Collections.unmodifiableList(new ArrayList<>(raw));
  }

  private static Map<String, Object> buildMap(List<Object> records) {
    if (records.isEmpty()) {
      return Collections.emptyMap();
    }
    Map<String, Object> out = new LinkedHashMap<>();
    for (int i = 0; i < records.size(); i += 1) {
      Object record = records.get(i);
      out.put(extractRecordKey(record, i), record);
    }
    return Collections.unmodifiableMap(out);
  }

  private static String extractRecordKey(Object record, int index) {
    if (record == null) {
      return "row-" + index;
    }

    Object fromGetter = invokeNoArg(record, "getId");
    if (fromGetter == null) {
      fromGetter = invokeNoArg(record, "id");
    }
    if (fromGetter != null) {
      return String.valueOf(fromGetter);
    }

    Object fromField = readField(record, "id");
    if (fromField == null) {
      fromField = readField(record, "Id");
    }
    if (fromField != null) {
      return String.valueOf(fromField);
    }

    return "row-" + index;
  }

  private static Object invokeNoArg(Object receiver, String name) {
    try {
      Method method = receiver.getClass().getMethod(name);
      method.setAccessible(true);
      return method.invoke(receiver);
    } catch (Exception ignored) {
      return null;
    }
  }

  private static Object readField(Object receiver, String name) {
    try {
      Field field = receiver.getClass().getDeclaredField(name);
      field.setAccessible(true);
      return field.get(receiver);
    } catch (Exception ignored) {
      return null;
    }
  }

  private static final class State {
    boolean executing;
    boolean before;
    boolean after;
    Operation operation;
    List<Object> newRecords = Collections.emptyList();
    List<Object> oldRecords = Collections.emptyList();
    Map<String, Object> newMap = Collections.emptyMap();
    Map<String, Object> oldMap = Collections.emptyMap();
  }

  private record HandlerKey(String sobjectType, boolean before, Operation operation) {}

  private static final class Registry {
    final Map<HandlerKey, List<Runnable>> handlers = new LinkedHashMap<>();
  }
}
