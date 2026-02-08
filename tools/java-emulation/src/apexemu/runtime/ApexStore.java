package apexemu.runtime;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class ApexStore {
  private static final Pattern FROM_PATTERN = Pattern.compile("(?i)\\bfrom\\s+([a-zA-Z_][\\w]*)");
  private static final Pattern LIMIT_PATTERN = Pattern.compile("(?i)\\blimit\\s+(\\d+)");
  private static final Pattern WHERE_KEYWORD = Pattern.compile("(?i)\\bwhere\\b");
  private static final Pattern WHERE_PATTERN =
      Pattern.compile("(?i)^([a-zA-Z_][\\w]*)\\s*(>=|<=|!=|=|>|<)\\s*(.+)$");
  private static final Pattern ORDER_BY_KEYWORD = Pattern.compile("(?i)\\border\\s+by\\b");
  private static final Pattern ORDER_BY_PATTERN =
      Pattern.compile("(?i)^([a-zA-Z_][\\w]*)(?:\\s+(asc|desc))?$");
  private static final Pattern AND_SPLIT_PATTERN = Pattern.compile("(?i)\\s+and\\s+");
  private static final ThreadLocal<State> STATE = ThreadLocal.withInitial(State::new);

  private ApexStore() {}

  static void reset() {
    STATE.set(new State());
  }

  static Database.SaveResult[] insert(Collection<ApexSObject> records, boolean allOrNone) {
    return apply(records, allOrNone, ApexStore::insertOne);
  }

  static Database.SaveResult[] update(Collection<ApexSObject> records, boolean allOrNone) {
    return apply(records, allOrNone, ApexStore::updateOne);
  }

  static Database.SaveResult[] upsert(Collection<ApexSObject> records, boolean allOrNone) {
    return apply(records, allOrNone, ApexStore::upsertOne);
  }

  static Database.SaveResult[] delete(Collection<ApexSObject> records, boolean allOrNone) {
    return apply(records, allOrNone, ApexStore::deleteOne);
  }

  static Database.SaveResult[] undelete(Collection<ApexSObject> records, boolean allOrNone) {
    return apply(records, allOrNone, ApexStore::undeleteOne);
  }

  static long setSavepoint() {
    State state = STATE.get();
    long token = state.nextSavepointToken();
    state.savepoints.add(new SavepointSnapshot(token, snapshotOf(state)));
    return token;
  }

  static void rollback(long token) {
    if (token <= 0L) {
      throw new IllegalArgumentException("invalid savepoint token: " + token);
    }

    State state = STATE.get();
    int rollbackIndex = -1;
    StateSnapshot snapshot = null;
    for (int i = state.savepoints.size() - 1; i >= 0; i -= 1) {
      SavepointSnapshot candidate = state.savepoints.get(i);
      if (candidate.token == token) {
        rollbackIndex = i;
        snapshot = candidate.snapshot;
        break;
      }
    }

    if (rollbackIndex < 0 || snapshot == null) {
      throw new IllegalArgumentException("savepoint not found: " + token);
    }

    restore(state, snapshot);
    state.savepoints.subList(rollbackIndex, state.savepoints.size()).clear();
  }

  static List<ApexSObject> query(String soql) {
    QuerySpec spec = parseQuerySpec(soql);
    List<ApexSObject> all = scan(spec, false);
    List<ApexSObject> out = new ArrayList<>(all.size());
    for (ApexSObject row : all) {
      out.add(row.copy());
    }
    Limits.addSoql(1);
    Limits.addHeapBytes(out.size() * 256L);
    return out;
  }

  static int countQuery(String soql) {
    QuerySpec spec = parseQuerySpec(soql);
    int count = scan(spec, true).size();
    Limits.addSoql(1);
    return count;
  }

  private static Database.SaveResult[] apply(
      Collection<ApexSObject> records, boolean allOrNone, DmlOperation operation) {
    List<ApexSObject> normalized = normalize(records);
    if (normalized.isEmpty()) {
      return new Database.SaveResult[0];
    }

    State state = STATE.get();
    Limits.addDml(1);

    if (allOrNone) {
      StateSnapshot original = snapshotOf(state);
      Database.SaveResult[] successes = new Database.SaveResult[normalized.size()];
      for (int i = 0; i < normalized.size(); i += 1) {
        ApexSObject record = normalized.get(i);
        try {
          String id = operation.apply(state, record);
          successes[i] = success(id);
        } catch (RuntimeException error) {
          restore(state, original);
          FailureInfo root = classifyFailure(error);
          Database.SaveResult[] failures = new Database.SaveResult[normalized.size()];
          for (int j = 0; j < normalized.size(); j += 1) {
            ApexSObject row = normalized.get(j);
            failures[j] = failure(row == null ? null : row.id(), root, "allOrNone rollback");
          }
          return failures;
        }
      }
      return successes;
    }

    Database.SaveResult[] out = new Database.SaveResult[normalized.size()];
    for (int i = 0; i < normalized.size(); i += 1) {
      ApexSObject record = normalized.get(i);
      try {
        String id = operation.apply(state, record);
        out[i] = success(id);
      } catch (RuntimeException error) {
        out[i] = failure(record == null ? null : record.id(), classifyFailure(error), null);
      }
    }
    return out;
  }

  private static String insertOne(State state, ApexSObject raw) {
    ApexSObject record = requireRecord(raw);
    validateForInsert(record);
    ApexSObject stored = record.copy();

    String id = normalizeId(stored.id());
    if (id == null) {
      id = nextId(state, stored.type());
      stored.withId(id);
      record.withId(id);
    }

    if (hasIdCollision(state, stored.type(), id)) {
      throw new IllegalArgumentException("duplicate id for insert: " + stored.type() + "#" + id);
    }

    Map<String, ApexSObject> bucket = state.active.computeIfAbsent(stored.type(), ignored -> new LinkedHashMap<>());
    bucket.put(id, stored);
    return id;
  }

  private static String updateOne(State state, ApexSObject raw) {
    ApexSObject record = requireRecord(raw);
    validateForUpdate(record);
    String id = requireId(record, "update");

    Map<String, ApexSObject> bucket = state.active.get(record.type());
    if (bucket == null || !bucket.containsKey(id)) {
      throw new IllegalArgumentException("record not found for update: " + record.type() + "#" + id);
    }

    ApexSObject stored = bucket.get(id).copy();
    for (Map.Entry<String, Object> field : record.fields().entrySet()) {
      stored.set(field.getKey(), field.getValue());
    }
    bucket.put(id, stored);
    return id;
  }

  private static String upsertOne(State state, ApexSObject raw) {
    ApexSObject record = requireRecord(raw);
    String id = normalizeId(record.id());

    if (id != null) {
      Map<String, ApexSObject> bucket = state.active.get(record.type());
      if (bucket != null && bucket.containsKey(id)) {
        return updateOne(state, record);
      }
    }

    return insertOne(state, record);
  }

  private static String deleteOne(State state, ApexSObject raw) {
    ApexSObject record = requireRecord(raw);
    String id = requireId(record, "delete");

    Map<String, ApexSObject> activeBucket = state.active.get(record.type());
    if (activeBucket == null || !activeBucket.containsKey(id)) {
      throw new IllegalArgumentException("record not found for delete: " + record.type() + "#" + id);
    }

    ApexSObject removed = activeBucket.remove(id);
    state.deleted.computeIfAbsent(record.type(), ignored -> new LinkedHashMap<>()).put(id, removed);
    return id;
  }

  private static String undeleteOne(State state, ApexSObject raw) {
    ApexSObject record = requireRecord(raw);
    String id = requireId(record, "undelete");

    Map<String, ApexSObject> deletedBucket = state.deleted.get(record.type());
    if (deletedBucket == null || !deletedBucket.containsKey(id)) {
      throw new IllegalArgumentException("record not found for undelete: " + record.type() + "#" + id);
    }

    Map<String, ApexSObject> activeBucket =
        state.active.computeIfAbsent(record.type(), ignored -> new LinkedHashMap<>());
    if (activeBucket.containsKey(id)) {
      throw new IllegalArgumentException("active record already exists for undelete: " + record.type() + "#" + id);
    }

    activeBucket.put(id, deletedBucket.remove(id));
    return id;
  }

  private static List<ApexSObject> scan(QuerySpec spec, boolean countOnly) {
    State state = STATE.get();
    Map<String, ApexSObject> bucket = state.active.get(spec.sobjectType);
    if (bucket == null || bucket.isEmpty()) {
      return List.of();
    }

    List<ApexSObject> out = new ArrayList<>();
    for (ApexSObject row : bucket.values()) {
      if (!matchesWhere(row, spec.whereClauses)) {
        continue;
      }
      out.add(row);
    }

    if (!countOnly && spec.orderByField != null) {
      out.sort(
          (left, right) -> {
            int compared = compareValues(left.get(spec.orderByField), right.get(spec.orderByField));
            return spec.orderDescending ? -compared : compared;
          });
    }

    if (spec.limit > 0 && out.size() > spec.limit) {
      return new ArrayList<>(out.subList(0, spec.limit));
    }
    return out;
  }

  private static boolean matchesWhere(ApexSObject row, List<WhereClause> whereClauses) {
    if (whereClauses == null || whereClauses.isEmpty()) {
      return true;
    }

    for (WhereClause clause : whereClauses) {
      if (!matchesClause(row, clause)) {
        return false;
      }
    }
    return true;
  }

  private static boolean matchesClause(ApexSObject row, WhereClause clause) {
    Object value = row.get(clause.field);
    Object whereLiteral = clause.literal;
    return switch (clause.operator) {
      case "=" -> compareEquality(value, whereLiteral);
      case "!=" -> !compareEquality(value, whereLiteral);
      case ">" -> compareRange(value, whereLiteral, ">");
      case ">=" -> compareRange(value, whereLiteral, ">=");
      case "<" -> compareRange(value, whereLiteral, "<");
      case "<=" -> compareRange(value, whereLiteral, "<=");
      default -> false;
    };
  }

  private static boolean compareEquality(Object value, Object whereLiteral) {
    if (whereLiteral == null) {
      return value == null;
    }
    if (value == null) {
      return false;
    }

    if (whereLiteral instanceof Number numberLiteral && value instanceof Number valueNumber) {
      return Double.compare(numberLiteral.doubleValue(), valueNumber.doubleValue()) == 0;
    }
    if (whereLiteral instanceof Boolean literalBoolean && value instanceof Boolean valueBoolean) {
      return literalBoolean.equals(valueBoolean);
    }
    if (whereLiteral instanceof Boolean literalBoolean) {
      return String.valueOf(value).equalsIgnoreCase(literalBoolean.toString());
    }
    return Objects.equals(String.valueOf(whereLiteral), String.valueOf(value));
  }

  private static boolean compareRange(Object value, Object whereLiteral, String operator) {
    if (value == null || whereLiteral == null) {
      return false;
    }
    int compared = compareValues(value, whereLiteral);
    return switch (operator) {
      case ">" -> compared > 0;
      case ">=" -> compared >= 0;
      case "<" -> compared < 0;
      case "<=" -> compared <= 0;
      default -> false;
    };
  }

  private static int compareValues(Object left, Object right) {
    if (left == null && right == null) {
      return 0;
    }
    if (left == null) {
      return 1;
    }
    if (right == null) {
      return -1;
    }

    Double leftNumber = toNumber(left);
    Double rightNumber = toNumber(right);
    if (leftNumber != null && rightNumber != null) {
      return Double.compare(leftNumber, rightNumber);
    }

    String leftValue = String.valueOf(left);
    String rightValue = String.valueOf(right);
    return leftValue.compareTo(rightValue);
  }

  private static QuerySpec parseQuerySpec(String rawSoql) {
    if (rawSoql == null || rawSoql.isBlank()) {
      throw new IllegalArgumentException("SOQL cannot be blank");
    }

    String soql = sanitize(rawSoql);
    Matcher fromMatcher = FROM_PATTERN.matcher(soql);
    if (!fromMatcher.find()) {
      throw new IllegalArgumentException("SOQL must contain FROM <SObject>: " + rawSoql);
    }
    String sobjectType = fromMatcher.group(1);

    Matcher whereKeyword = WHERE_KEYWORD.matcher(soql);
    int whereStart = -1;
    int whereEnd = -1;
    if (whereKeyword.find()) {
      whereStart = whereKeyword.start();
      whereEnd = whereKeyword.end();
    }

    Matcher orderByKeyword = ORDER_BY_KEYWORD.matcher(soql);
    int orderByStart = -1;
    int orderByEnd = -1;
    if (orderByKeyword.find()) {
      orderByStart = orderByKeyword.start();
      orderByEnd = orderByKeyword.end();
    }

    int limit = 0;
    int limitStart = -1;
    Matcher limitMatcher = LIMIT_PATTERN.matcher(soql);
    if (limitMatcher.find()) {
      limitStart = limitMatcher.start();
      limit = Integer.parseInt(limitMatcher.group(1));
    }

    if (whereStart >= 0 && orderByStart >= 0 && orderByStart < whereStart) {
      throw new IllegalArgumentException("ORDER BY before WHERE is not supported: " + rawSoql);
    }

    List<WhereClause> whereClauses = List.of();
    if (whereStart >= 0) {
      int whereBodyEnd = nextClauseStart(soql.length(), whereEnd, orderByStart, limitStart);
      String whereExpr = soql.substring(whereEnd, whereBodyEnd).trim();
      whereClauses = parseWhereClauses(whereExpr, rawSoql);
    }

    String orderByField = null;
    boolean orderDescending = false;
    if (orderByStart >= 0) {
      int orderByBodyEnd = limitStart > orderByEnd ? limitStart : soql.length();
      String orderByExpr = soql.substring(orderByEnd, orderByBodyEnd).trim();
      Matcher orderByMatcher = ORDER_BY_PATTERN.matcher(orderByExpr);
      if (!orderByMatcher.matches()) {
        throw new IllegalArgumentException("only ORDER BY <field> [ASC|DESC] is supported: " + rawSoql);
      }
      orderByField = orderByMatcher.group(1);
      String direction = orderByMatcher.group(2);
      orderDescending = direction != null && direction.equalsIgnoreCase("desc");
    }

    return new QuerySpec(sobjectType, whereClauses, orderByField, orderDescending, limit);
  }

  private static String sanitize(String soql) {
    String out = soql.trim();
    if (out.startsWith("[") && out.endsWith("]")) {
      out = out.substring(1, out.length() - 1).trim();
    }
    if (out.endsWith(";")) {
      out = out.substring(0, out.length() - 1).trim();
    }
    return out;
  }

  private static int nextClauseStart(int defaultEnd, int bodyStart, int orderByStart, int limitStart) {
    int end = defaultEnd;
    if (orderByStart >= 0 && orderByStart > bodyStart) {
      end = Math.min(end, orderByStart);
    }
    if (limitStart >= 0 && limitStart > bodyStart) {
      end = Math.min(end, limitStart);
    }
    return end;
  }

  private static List<WhereClause> parseWhereClauses(String whereExpr, String rawSoql) {
    if (whereExpr == null || whereExpr.isBlank()) {
      throw new IllegalArgumentException("WHERE clause cannot be blank: " + rawSoql);
    }

    String[] clauseTexts = AND_SPLIT_PATTERN.split(whereExpr.trim());
    List<WhereClause> clauses = new ArrayList<>(clauseTexts.length);
    for (String clauseText : clauseTexts) {
      Matcher whereMatcher = WHERE_PATTERN.matcher(clauseText.trim());
      if (!whereMatcher.matches()) {
        throw new IllegalArgumentException(
            "only WHERE with AND and operators (=, !=, >, >=, <, <=) is supported: " + rawSoql);
      }
      clauses.add(
          new WhereClause(
              whereMatcher.group(1), whereMatcher.group(2), parseLiteral(whereMatcher.group(3).trim())));
    }
    return clauses;
  }

  private static Object parseLiteral(String raw) {
    String value = raw.trim();
    if ((value.startsWith("'") && value.endsWith("'")) || (value.startsWith("\"") && value.endsWith("\""))) {
      return value.substring(1, value.length() - 1);
    }
    if ("null".equalsIgnoreCase(value)) {
      return null;
    }
    if ("true".equalsIgnoreCase(value)) {
      return Boolean.TRUE;
    }
    if ("false".equalsIgnoreCase(value)) {
      return Boolean.FALSE;
    }
    try {
      if (value.contains(".")) {
        return Double.parseDouble(value);
      }
      return Long.parseLong(value);
    } catch (NumberFormatException ignored) {
      return value;
    }
  }

  private static Double toNumber(Object value) {
    if (value instanceof Number number) {
      return number.doubleValue();
    }
    if (value instanceof String text) {
      try {
        if (text.contains(".")) {
          return Double.parseDouble(text);
        }
        return (double) Long.parseLong(text);
      } catch (NumberFormatException ignored) {
        return null;
      }
    }
    return null;
  }

  private static ApexSObject requireRecord(ApexSObject record) {
    if (record == null) {
      throw new IllegalArgumentException("record cannot be null");
    }
    return record;
  }

  private static void validateForInsert(ApexSObject record) {
    Schema.ObjectDefinition definition = Schema.find(record.type());
    if (definition == null) {
      return;
    }
    validateDefinedFields(record, definition);

    for (Schema.FieldDefinition field : definition.fields.values()) {
      if (!field.required) {
        continue;
      }
      if (!record.hasField(field.name) || record.get(field.name) == null) {
        throw new DmlFailure(
            "REQUIRED_FIELD_MISSING", "required field missing: " + field.name, new String[] {field.name});
      }
    }
  }

  private static void validateForUpdate(ApexSObject record) {
    Schema.ObjectDefinition definition = Schema.find(record.type());
    if (definition == null) {
      return;
    }
    validateDefinedFields(record, definition);
  }

  private static void validateDefinedFields(ApexSObject record, Schema.ObjectDefinition definition) {
    for (Map.Entry<String, Object> entry : record.fields().entrySet()) {
      Schema.FieldDefinition field = definition.field(entry.getKey());
      if (field == null) {
        throw new DmlFailure(
            "INVALID_FIELD_FOR_INSERT_UPDATE",
            "field is not defined in schema: " + entry.getKey(),
            new String[] {entry.getKey()});
      }

      Object value = entry.getValue();
      if (value == null) {
        if (field.required) {
          throw new DmlFailure(
              "REQUIRED_FIELD_MISSING", "required field missing: " + field.name, new String[] {field.name});
        }
        continue;
      }

      if (!isTypeCompatible(field.type, value)) {
        throw new DmlFailure(
            "INVALID_TYPE_ON_FIELD_IN_RECORD",
            "invalid type for field " + field.name + ": expected " + field.type + " but got " + value.getClass().getSimpleName(),
            new String[] {field.name});
      }
    }
  }

  private static boolean isTypeCompatible(Schema.FieldType expected, Object value) {
    return switch (expected) {
      case STRING -> value instanceof String;
      case BOOLEAN -> value instanceof Boolean;
      case INTEGER -> value instanceof Integer;
      case LONG -> value instanceof Long || value instanceof Integer;
      case DECIMAL, DOUBLE -> value instanceof Number;
      case ID -> value instanceof String text && !text.isBlank();
    };
  }

  private static String requireId(ApexSObject record, String operation) {
    String id = normalizeId(record.id());
    if (id == null) {
      throw new IllegalArgumentException(operation + " requires id: " + record.type());
    }
    return id;
  }

  private static boolean hasIdCollision(State state, String type, String id) {
    Map<String, ApexSObject> activeBucket = state.active.get(type);
    if (activeBucket != null && activeBucket.containsKey(id)) {
      return true;
    }
    Map<String, ApexSObject> deletedBucket = state.deleted.get(type);
    return deletedBucket != null && deletedBucket.containsKey(id);
  }

  private static String normalizeId(String id) {
    if (id == null) {
      return null;
    }
    String trimmed = id.trim();
    if (trimmed.isEmpty()) {
      return null;
    }
    return trimmed;
  }

  private static Database.SaveResult success(String id) {
    return new Database.SaveResult(true, id, new Database.Error[0]);
  }

  private static Database.SaveResult failure(String id, FailureInfo info, String messagePrefix) {
    String message = info.message;
    if (messagePrefix != null && !messagePrefix.isBlank()) {
      message = messagePrefix + ": " + message;
    }
    return new Database.SaveResult(
        false, id, new Database.Error[] {new Database.Error(info.statusCode, message, info.fields)});
  }

  private static FailureInfo classifyFailure(Throwable error) {
    if (error instanceof DmlFailure dmlFailure) {
      return new FailureInfo(dmlFailure.statusCode, dmlFailure.getMessage(), dmlFailure.fields);
    }
    String message = messageOrDefault(error);
    if (message.contains("requires id")) {
      return new FailureInfo("REQUIRED_FIELD_MISSING", message, new String[] {"Id"});
    }
    if (message.contains("duplicate id")) {
      return new FailureInfo("DUPLICATE_VALUE", message, new String[] {"Id"});
    }
    if (message.contains("record not found")) {
      return new FailureInfo("INVALID_CROSS_REFERENCE_KEY", message, new String[] {"Id"});
    }
    return new FailureInfo("DML_ERROR", message, new String[0]);
  }

  private static String messageOrDefault(Throwable error) {
    if (error == null) {
      return "unknown error";
    }
    String message = error.getMessage();
    if (message == null || message.isBlank()) {
      return error.getClass().getSimpleName();
    }
    return message;
  }

  private static List<ApexSObject> normalize(Collection<ApexSObject> records) {
    if (records == null || records.isEmpty()) {
      return List.of();
    }
    List<ApexSObject> out = new ArrayList<>(records.size());
    out.addAll(records);
    return out;
  }

  private static StateSnapshot snapshotOf(State state) {
    return new StateSnapshot(copyBuckets(state.active), copyBuckets(state.deleted), state.idSequence);
  }

  private static void restore(State state, StateSnapshot snapshot) {
    state.active.clear();
    state.active.putAll(copyBuckets(snapshot.active));
    state.deleted.clear();
    state.deleted.putAll(copyBuckets(snapshot.deleted));
    state.idSequence = snapshot.idSequence;
  }

  private static Map<String, Map<String, ApexSObject>> copyBuckets(Map<String, Map<String, ApexSObject>> source) {
    Map<String, Map<String, ApexSObject>> out = new LinkedHashMap<>();
    for (Map.Entry<String, Map<String, ApexSObject>> bucket : source.entrySet()) {
      Map<String, ApexSObject> rows = new LinkedHashMap<>();
      for (Map.Entry<String, ApexSObject> row : bucket.getValue().entrySet()) {
        rows.put(row.getKey(), row.getValue().copy());
      }
      out.put(bucket.getKey(), rows);
    }
    return out;
  }

  private static String nextId(State state, String type) {
    state.idSequence += 1L;
    String prefix = type.length() >= 3 ? type.substring(0, 3) : String.format("%-3s", type).replace(' ', 'X');
    return prefix + String.format("%015d", state.idSequence);
  }

  private interface DmlOperation {
    String apply(State state, ApexSObject record);
  }

  private record FailureInfo(String statusCode, String message, String[] fields) {}

  private record WhereClause(String field, String operator, Object literal) {}

  private record QuerySpec(
      String sobjectType, List<WhereClause> whereClauses, String orderByField, boolean orderDescending, int limit) {}

  private static final class DmlFailure extends RuntimeException {
    final String statusCode;
    final String[] fields;

    DmlFailure(String statusCode, String message, String[] fields) {
      super(message);
      this.statusCode = statusCode == null ? "DML_ERROR" : statusCode;
      this.fields = fields == null ? new String[0] : fields.clone();
    }
  }

  private record StateSnapshot(
      Map<String, Map<String, ApexSObject>> active,
      Map<String, Map<String, ApexSObject>> deleted,
      long idSequence) {}

  private record SavepointSnapshot(long token, StateSnapshot snapshot) {}

  private static final class State {
    final Map<String, Map<String, ApexSObject>> active = new LinkedHashMap<>();
    final Map<String, Map<String, ApexSObject>> deleted = new LinkedHashMap<>();
    final List<SavepointSnapshot> savepoints = new ArrayList<>();
    long idSequence;
    long savepointSequence;

    long nextSavepointToken() {
      savepointSequence += 1L;
      return savepointSequence;
    }
  }
}
