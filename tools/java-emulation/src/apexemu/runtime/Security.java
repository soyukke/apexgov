package apexemu.runtime;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

public final class Security {
  private Security() {}

  public static System.SObjectAccessDecision stripInaccessible(
      System.AccessType accessType, List<ApexSObject> records) {
    return stripInaccessible(accessType, records, false);
  }

  public static System.SObjectAccessDecision stripInaccessible(
      System.AccessType accessType, List<ApexSObject> records, boolean enforceRootObjectCRUD) {
    if (records == null || records.isEmpty()) {
      return new System.SObjectAccessDecision(records);
    }

    // Determine object type from first non-null record
    String objectType = null;
    for (ApexSObject r : records) {
      if (r != null && r.type() != null && !r.type().isBlank()) {
        objectType = r.type();
        break;
      }
    }

    // Check object-level CRUD access - throw NoAccessException if denied
    if (objectType != null) {
      Schema.DescribeSObjectResult objDescribe = new Schema.DescribeSObjectResult(objectType);
      boolean objectAccessible = switch (accessType) {
        case READABLE -> objDescribe.isAccessible();
        case CREATABLE -> objDescribe.isCreateable();
        case UPDATABLE -> objDescribe.isUpdateable();
        case UPSERTABLE -> objDescribe.isCreateable() && objDescribe.isUpdateable();
      };
      if (!objectAccessible) {
        throw new System.NoAccessException(
            "No access to entity '" + objectType + "': no access to entity");
      }
    }

    List<ApexSObject> stripped = new ArrayList<>(records.size());
    Map<String, Set<String>> removedFields = new LinkedHashMap<>();

    for (ApexSObject record : records) {
      if (record == null) {
        stripped.add(null);
        continue;
      }
      ApexSObject copy = record.copy();
      Set<String> retainSet = new java.util.HashSet<>();
      retainSet.add("id");
      Set<String> removed = new LinkedHashSet<>();

      Set<String> candidateFields = new LinkedHashSet<>();
      candidateFields.addAll(record.fields().keySet());
      if (record.hasStrictQueryAccess()) {
        candidateFields.addAll(record.queriedFieldsLower());
      }

      for (String fieldName : candidateFields) {
        if (fieldName == null || fieldName.isBlank() || "id".equalsIgnoreCase(fieldName)) {
          continue;
        }

        Object value = record.get(fieldName);

        // Check if this is a subquery/relationship field (List<ApexSObject>), including empty queried lists.
        if (value instanceof List<?> list && !list.isEmpty() && list.get(0) instanceof ApexSObject firstChild) {
          Schema.DescribeSObjectResult childDescribe =
              new Schema.DescribeSObjectResult(firstChild.type());
          if (accessType == System.AccessType.READABLE && !childDescribe.isAccessible()) {
            removed.add(fieldName);
            continue;
          }
          retainSet.add(fieldName.toLowerCase());
          continue;
        }
        if (accessType == System.AccessType.READABLE) {
          Schema.ChildRelationship childRel = Schema.resolveChildRelationship(record.type(), fieldName);
          if (childRel != null) {
            Schema.DescribeSObjectResult childDescribe =
                new Schema.DescribeSObjectResult(childRel.childType);
            if (!childDescribe.isAccessible()) {
              removed.add(fieldName);
              continue;
            }
            retainSet.add(fieldName.toLowerCase());
            continue;
          }
        }

        if (isFieldAccessible(accessType, record.type(), fieldName)) {
          retainSet.add(fieldName.toLowerCase());
        } else {
          removed.add(fieldName);
        }
      }

      copy.retainFields(retainSet);
      if (record.hasStrictQueryAccess()) {
        copy.markQueriedFields(retainSet);
      }

      if (!removed.isEmpty()) {
        String typeName = record.type() == null ? "Unknown" : record.type();
        Set<String> existing = removedFields.computeIfAbsent(typeName, k -> new LinkedHashSet<>());
        existing.addAll(removed);
      }
      stripped.add(copy);
    }
    return new System.SObjectAccessDecision(stripped, removedFields);
  }

  private static boolean isFieldAccessible(System.AccessType accessType, String objectType, String fieldName) {
    if (accessType == null || fieldName == null) {
      return true;
    }
    Schema.DescribeFieldResult dfr = new Schema.DescribeFieldResult(objectType, fieldName);
    return switch (accessType) {
      case READABLE -> dfr.isAccessible();
      case CREATABLE -> dfr.isCreateable();
      case UPDATABLE -> dfr.isUpdateable();
      case UPSERTABLE -> dfr.isCreateable() || dfr.isUpdateable();
    };
  }

  public static void checkInsert(String objType, List<String> fieldNames) {
    // no-op in emulation
  }

  public static void checkUpdate(String objType, List<String> fieldNames) {
    // no-op in emulation
  }

  public static void checkInsertByToken(Schema.SObjectType objType, List<Schema.SObjectField> fieldTokens) {
    // no-op in emulation
  }

  public static void checkUpdateByToken(Schema.SObjectType objType, List<Schema.SObjectField> fieldTokens) {
    // no-op in emulation
  }
}
