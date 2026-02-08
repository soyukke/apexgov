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

  private Trigger() {}

  public enum Operation {
    INSERT,
    UPDATE,
    DELETE,
    UNDELETE
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
    State current = new State();
    current.executing = true;
    current.before = isBefore;
    current.after = !isBefore;
    current.operation = operation;
    current.newRecords = toObjectList(newRecords);
    current.oldRecords = toObjectList(oldRecords);
    current.newMap = buildMap(current.newRecords);
    current.oldMap = buildMap(current.oldRecords);
    STATE.set(current);

    try {
      handler.run();
    } finally {
      STATE.set(previous);
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

  public static List<Object> getNew() {
    return STATE.get().newRecords;
  }

  public static List<Object> getOld() {
    return STATE.get().oldRecords;
  }

  public static Map<String, Object> getNewMap() {
    return STATE.get().newMap;
  }

  public static Map<String, Object> getOldMap() {
    return STATE.get().oldMap;
  }

  public static int size() {
    State state = STATE.get();
    if (!state.newRecords.isEmpty()) {
      return state.newRecords.size();
    }
    return state.oldRecords.size();
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
}
