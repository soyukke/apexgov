package apexemu.runtime;

import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

public final class Schema {
  private static final ThreadLocal<State> STATE = ThreadLocal.withInitial(State::new);
  private static final ThreadLocal<String> CURRENT_PROFILE_ID = ThreadLocal.withInitial(() -> null);
  private static final char[] CUSTOM_KEY_PREFIX_ALPHABET =
      "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".toCharArray();
  private static final Map<String, String> CUSTOM_KEY_PREFIX_BY_TYPE = new LinkedHashMap<>();
  private static final Set<String> CUSTOM_KEY_PREFIXES_IN_USE = new LinkedHashSet<>();
  private static final String MINIMUM_ACCESS_PROFILE_ID = "00e000000000001";
  private static final String MARKETING_USER_PROFILE_ID = "00e000000000004";
  public static final SObjectTypeNamespace sObjectType = new SObjectTypeNamespace();

  private Schema() {}

  public static ObjectBuilder object(String type) {
    return new ObjectBuilder(type);
  }

  public static void registerFieldSet(String typeName, String fieldSetName, String... fieldPaths) {
    if (typeName == null || typeName.isBlank() || fieldSetName == null || fieldSetName.isBlank()) {
      return;
    }
    List<FieldSetMember> members = new ArrayList<>();
    if (fieldPaths != null) {
      for (String fieldPath : fieldPaths) {
        if (fieldPath == null || fieldPath.isBlank()) {
          continue;
        }
        members.add(new FieldSetMember(typeName, fieldPath.trim()));
      }
    }
    FieldSet fieldSet = new FieldSet(typeName.trim(), fieldSetName.trim(), members);
    State state = STATE.get();
    state.fieldSets
        .computeIfAbsent(normalize(typeName), ignored -> new LinkedHashMap<>())
        .put(normalize(fieldSetName), fieldSet);
  }

  public static void clear() {
    STATE.set(new State());
    CURRENT_PROFILE_ID.set(null);
  }

  static String getCurrentProfileId() {
    return CURRENT_PROFILE_ID.get();
  }

  static void setCurrentProfileId(String profileId) {
    CURRENT_PROFILE_ID.set(profileId);
  }

  static String keyPrefixForTypeName(String typeName) {
    if (typeName == null || typeName.isBlank()) {
      return "a00";
    }
    String normalized = typeName.trim();
    if (normalized.equalsIgnoreCase("RecordType")) return "012";
    if (normalized.equalsIgnoreCase("Account")) return "001";
    if (normalized.equalsIgnoreCase("Contact")) return "003";
    if (normalized.equalsIgnoreCase("Lead")) return "00Q";
    if (normalized.equalsIgnoreCase("Opportunity")) return "006";
    if (normalized.equalsIgnoreCase("Case")) return "500";
    if (normalized.equalsIgnoreCase("Task")) return "00T";
    if (normalized.equalsIgnoreCase("Event")) return "00U";
    if (normalized.equalsIgnoreCase("User")) return "005";
    if (normalized.equalsIgnoreCase("Group")) return "00G";
    if (normalized.equalsIgnoreCase("CollaborationGroup")) return "0F9";
    if (normalized.equalsIgnoreCase("FeedItem")) return "0D5";
    if (normalized.equalsIgnoreCase("Report")) return "00O";
    if (normalized.equalsIgnoreCase("AsyncApexJob")) return "707";
    if (normalized.equalsIgnoreCase("Profile")) return "00e";
    if (normalized.equalsIgnoreCase("PermissionSet")) return "0PS";
    if (normalized.equalsIgnoreCase("PermissionSetAssignment")) return "0Pa";
    if (normalized.endsWith("__mdt")) return customKeyPrefixForType(normalized, 'm');
    if (normalized.endsWith("__e")) return customKeyPrefixForType(normalized, 'e');
    if (normalized.endsWith("__c")) return customKeyPrefixForType(normalized, 'a');
    return customKeyPrefixForType(normalized, 'a');
  }

  static String resolveTypeNameByKeyPrefix(String keyPrefix) {
    if (keyPrefix == null || keyPrefix.isBlank()) {
      return null;
    }
    String normalizedPrefix = keyPrefix.trim();

    String standardType = standardTypeByKeyPrefix(normalizedPrefix);
    if (standardType != null) {
      return standardType;
    }

    for (ObjectDefinition def : STATE.get().definitions.values()) {
      if (def == null || def.type == null || def.type.isBlank()) {
        continue;
      }
      String typeName = def.type.trim();
      String prefix = keyPrefixForTypeName(typeName);
      if (prefix != null && prefix.equalsIgnoreCase(normalizedPrefix)) {
        return typeName;
      }
      String bareType = stripNamespace(typeName);
      if (bareType != null && !bareType.equalsIgnoreCase(typeName)) {
        String barePrefix = keyPrefixForTypeName(bareType);
        if (barePrefix != null && barePrefix.equalsIgnoreCase(normalizedPrefix)) {
          return bareType;
        }
      }
    }

    synchronized (Schema.class) {
      for (Map.Entry<String, String> entry : CUSTOM_KEY_PREFIX_BY_TYPE.entrySet()) {
        String entryPrefix = entry.getValue();
        if (entryPrefix != null && entryPrefix.equalsIgnoreCase(normalizedPrefix)) {
          return entry.getKey();
        }
      }
    }
    return null;
  }

  private static String standardTypeByKeyPrefix(String keyPrefix) {
    if (keyPrefix == null || keyPrefix.isBlank()) {
      return null;
    }
    String normalized = keyPrefix.trim().toLowerCase();
    return switch (normalized) {
      case "012" -> "RecordType";
      case "001" -> "Account";
      case "003" -> "Contact";
      case "00q" -> "Lead";
      case "006" -> "Opportunity";
      case "500" -> "Case";
      case "00t" -> "Task";
      case "00u" -> "Event";
      case "005" -> "User";
      case "00g" -> "Group";
      case "0f9" -> "CollaborationGroup";
      case "0d5" -> "FeedItem";
      case "00o" -> "Report";
      case "707" -> "AsyncApexJob";
      case "00e" -> "Profile";
      case "0ps" -> "PermissionSet";
      case "0pa" -> "PermissionSetAssignment";
      default -> null;
    };
  }

  private static String customKeyPrefixForType(String typeName, char lead) {
    if (typeName == null || typeName.isBlank()) {
      return lead + "00";
    }
    String key = normalize(typeName);
    synchronized (Schema.class) {
      String existing = CUSTOM_KEY_PREFIX_BY_TYPE.get(key);
      if (existing != null) {
        return existing;
      }

      int bucketSize = CUSTOM_KEY_PREFIX_ALPHABET.length * CUSTOM_KEY_PREFIX_ALPHABET.length;
      int seed = Math.floorMod(key.hashCode(), bucketSize);
      for (int offset = 0; offset < bucketSize; offset++) {
        int slot = (seed + offset) % bucketSize;
        char first = CUSTOM_KEY_PREFIX_ALPHABET[slot / CUSTOM_KEY_PREFIX_ALPHABET.length];
        char second = CUSTOM_KEY_PREFIX_ALPHABET[slot % CUSTOM_KEY_PREFIX_ALPHABET.length];
        String candidate = new String(new char[] {lead, first, second});
        if (isReservedStandardKeyPrefix(candidate)) {
          continue;
        }
        if (CUSTOM_KEY_PREFIXES_IN_USE.contains(candidate)) {
          continue;
        }
        CUSTOM_KEY_PREFIX_BY_TYPE.put(key, candidate);
        CUSTOM_KEY_PREFIXES_IN_USE.add(candidate);
        return candidate;
      }

      String fallback = lead + "00";
      CUSTOM_KEY_PREFIX_BY_TYPE.put(key, fallback);
      return fallback;
    }
  }

  private static boolean isReservedStandardKeyPrefix(String prefix) {
    if (prefix == null || prefix.isBlank()) {
      return false;
    }
    return prefix.equalsIgnoreCase("012")
        || prefix.equalsIgnoreCase("001")
        || prefix.equalsIgnoreCase("003")
        || prefix.equalsIgnoreCase("00Q")
        || prefix.equalsIgnoreCase("006")
        || prefix.equalsIgnoreCase("500")
        || prefix.equalsIgnoreCase("00T")
        || prefix.equalsIgnoreCase("00U")
        || prefix.equalsIgnoreCase("005")
        || prefix.equalsIgnoreCase("00G")
        || prefix.equalsIgnoreCase("0F9")
        || prefix.equalsIgnoreCase("0D5")
        || prefix.equalsIgnoreCase("00O")
        || prefix.equalsIgnoreCase("707")
        || prefix.equalsIgnoreCase("00e")
        || prefix.equalsIgnoreCase("0PS")
        || prefix.equalsIgnoreCase("0Pa");
  }

  public static Map<String, SObjectType> getGlobalDescribe() {
    Map<String, SObjectType> out = new LinkedHashMap<>();
    for (ObjectDefinition def : STATE.get().definitions.values()) {
      if (def == null || def.type == null || def.type.isBlank()) {
        continue;
      }
      SObjectType token = new SObjectType(def.type);
      addDescribeAlias(out, def.type, token);
      String bareType = stripNamespace(def.type);
      if (bareType != null && !bareType.equalsIgnoreCase(def.type)) {
        addDescribeAlias(out, bareType, token);
      }
    }
    addDescribeAlias(out, "Account", SObjectType.Account);
    addDescribeAlias(out, "Contact", SObjectType.Contact);
    addDescribeAlias(out, "Lead", SObjectType.Lead);
    addDescribeAlias(out, "Opportunity", SObjectType.Opportunity);
    addDescribeAlias(out, "Task", SObjectType.Task);
    addDescribeAlias(out, "User", SObjectType.User);
    addDescribeAlias(out, "Profile", SObjectType.Profile);
    addDescribeAlias(out, "Group", SObjectType.Group);
    addDescribeAlias(out, "OpportunityLineItem", SObjectType.OpportunityLineItem);
    addDescribeAlias(out, "PricebookEntry", SObjectType.PricebookEntry);
    addKnownSObjectTypeAliases(out);
    return out;
  }

  private static void addDescribeAlias(Map<String, SObjectType> out, String typeName, SObjectType token) {
    if (out == null || typeName == null || typeName.isBlank() || token == null) {
      return;
    }
    out.put(typeName.toLowerCase(), token);
    out.put(typeName, token);
  }

  private static void addKnownSObjectTypeAliases(Map<String, SObjectType> out) {
    if (out == null) {
      return;
    }
    for (java.lang.reflect.Field field : SObjectType.class.getDeclaredFields()) {
      int modifiers = field.getModifiers();
      if (!Modifier.isStatic(modifiers) || !Modifier.isPublic(modifiers)) {
        continue;
      }
      if (!SObjectType.class.equals(field.getType())) {
        continue;
      }
      try {
        Object raw = field.get(null);
        if (!(raw instanceof SObjectType token)) {
          continue;
        }
        String typeName = token.getName();
        addDescribeAlias(out, typeName, token);
        String bareType = stripNamespace(typeName);
        if (bareType != null && !bareType.equalsIgnoreCase(typeName)) {
          addDescribeAlias(out, bareType, token);
        }
      } catch (IllegalAccessException ignored) {
      }
    }
  }

  private static String stripNamespace(String typeName) {
    if (typeName == null || typeName.isBlank()) {
      return typeName;
    }
    String trimmed = typeName.trim();
    int firstSeparator = trimmed.indexOf("__");
    if (firstSeparator <= 0) {
      return trimmed;
    }
    int secondSeparator = trimmed.indexOf("__", firstSeparator + 2);
    if (secondSeparator < 0) {
      return trimmed;
    }
    return trimmed.substring(firstSeparator + 2);
  }

  public static List<DescribeSObjectResult> describeSObjects(List<String> typeNames) {
    if (typeNames == null || typeNames.isEmpty()) {
      return new ArrayList<>();
    }
    List<DescribeSObjectResult> out = new ArrayList<>(typeNames.size());
    for (String typeName : typeNames) {
      out.add(new DescribeSObjectResult(typeName));
    }
    return out;
  }

  public static List<DescribeSObjectResult> describeSObjects(String[] typeNames) {
    if (typeNames == null || typeNames.length == 0) {
      return new ArrayList<>();
    }
    List<String> names = new ArrayList<>(typeNames.length);
    Collections.addAll(names, typeNames);
    return describeSObjects(names);
  }

  static void runAs(ApexSObject user, Runnable work) {
    if (work == null) {
      throw new IllegalArgumentException("runAs work cannot be null");
    }
    String previousProfileId = CURRENT_PROFILE_ID.get();
    String profileId = null;
    if (user != null) {
      Object rawProfileId = user.get("ProfileId");
      if (rawProfileId == null) {
        rawProfileId = user.get("profileId");
      }
      if (rawProfileId != null) {
        String value = String.valueOf(rawProfileId).trim();
        if (!value.isEmpty()) {
          profileId = value;
        }
      }
    }
    CURRENT_PROFILE_ID.set(profileId);
    try {
      work.run();
    } finally {
      CURRENT_PROFILE_ID.set(previousProfileId);
    }
  }

  static ObjectDefinition find(String type) {
    if (type == null || type.isBlank()) {
      return null;
    }
    return STATE.get().definitions.get(normalize(type));
  }

  static ChildRelationship resolveChildRelationship(String parentType, String relationshipName) {
    if (parentType == null || parentType.isBlank() || relationshipName == null || relationshipName.isBlank()) {
      return null;
    }

    String normalizedParent = normalize(parentType);
    String normalizedRelationship = normalize(relationshipName);
    ChildRelationship match = null;

    for (ObjectDefinition definition : STATE.get().definitions.values()) {
      if (definition == null || definition.fields == null || definition.fields.isEmpty()) {
        continue;
      }
      for (FieldDefinition field : definition.fields.values()) {
        if (field == null || field.referenceType == null || field.referenceType.isBlank()) {
          continue;
        }
        if (!normalize(field.referenceType).equals(normalizedParent)) {
          continue;
        }
        if (!matchesRelationshipName(definition.type, field, normalizedRelationship)) {
          continue;
        }

        ChildRelationship candidate = new ChildRelationship(definition.type, field.name);
        if (match == null) {
          match = candidate;
        } else if (!sameRelationship(match, candidate)) {
          return null;
        }
      }
    }

    if (match != null) {
      return match;
    }
    return findKnownChildRelationship(parentType, relationshipName);
  }

  static String resolveReferenceField(String rowType, String relationshipSegment) {
    ObjectDefinition definition = find(rowType);
    if (definition == null || relationshipSegment == null || relationshipSegment.isBlank()) {
      return null;
    }
    String normalizedSegment = normalize(relationshipSegment);
    String resolved = null;

    for (FieldDefinition field : definition.fields.values()) {
      if (field == null || field.referenceType == null || field.referenceType.isBlank()) {
        continue;
      }
      if (!matchesReferenceSegment(field, normalizedSegment)) {
        continue;
      }
      if (resolved != null && !resolved.equalsIgnoreCase(field.name)) {
        return null;
      }
      resolved = field.name;
    }
    return resolved;
  }

  private static boolean matchesRelationshipName(
      String childType, FieldDefinition field, String normalizedRelationship) {
    if (field.childRelationshipName != null
        && !field.childRelationshipName.isBlank()
        && normalize(field.childRelationshipName).equals(normalizedRelationship)) {
      return true;
    }

    if (childType != null && !childType.isBlank()) {
      String normalizedChildType = normalize(childType);
      if (normalizedChildType.equals(normalizedRelationship)) {
        return true;
      }

      String plural = pluralizeTypeName(childType);
      if (plural != null && !plural.isBlank() && normalize(plural).equals(normalizedRelationship)) {
        return true;
      }
    }
    return false;
  }

  private static boolean matchesReferenceSegment(FieldDefinition field, String normalizedSegment) {
    if (field == null || normalizedSegment == null || normalizedSegment.isBlank()) {
      return false;
    }

    String fieldName = field.name;
    if (fieldName != null && !fieldName.isBlank()) {
      if (fieldName.length() > 3 && fieldName.regionMatches(true, fieldName.length() - 3, "__c", 0, 3)) {
        String customRelationship = fieldName.substring(0, fieldName.length() - 3) + "__r";
        if (normalize(customRelationship).equals(normalizedSegment)) {
          return true;
        }
      }
      if (fieldName.length() > 2 && fieldName.regionMatches(true, fieldName.length() - 2, "Id", 0, 2)) {
        String standardRelationship = fieldName.substring(0, fieldName.length() - 2);
        if (normalize(standardRelationship).equals(normalizedSegment)) {
          return true;
        }
      }
    }

    if (field.referenceType != null && !field.referenceType.isBlank()) {
      String normalizedReferenceType = normalize(field.referenceType);
      if (normalizedReferenceType.equals(normalizedSegment)) {
        return true;
      }
      if (field.referenceType.length() > 3
          && field.referenceType.regionMatches(true, field.referenceType.length() - 3, "__c", 0, 3)) {
        String customRelationship = field.referenceType.substring(0, field.referenceType.length() - 3) + "__r";
        if (normalize(customRelationship).equals(normalizedSegment)) {
          return true;
        }
      }
    }
    return false;
  }

  private static String pluralizeTypeName(String type) {
    if (type == null || type.isBlank()) {
      return null;
    }
    String trimmed = type.trim();
    if (trimmed.length() > 3 && trimmed.regionMatches(true, trimmed.length() - 3, "__c", 0, 3)) {
      return trimmed.substring(0, trimmed.length() - 3) + "__r";
    }
    if (trimmed.length() > 1 && trimmed.endsWith("y")) {
      return trimmed.substring(0, trimmed.length() - 1) + "ies";
    }
    if (trimmed.endsWith("s")) {
      return trimmed;
    }
    return trimmed + "s";
  }

  private static boolean sameRelationship(ChildRelationship left, ChildRelationship right) {
    if (left == null || right == null) {
      return false;
    }
    return left.childType.equalsIgnoreCase(right.childType)
        && left.parentLinkField.equalsIgnoreCase(right.parentLinkField);
  }

  private static ChildRelationship findKnownChildRelationship(
      String parentType, String relationshipName) {
    if (parentType == null || parentType.isBlank() || relationshipName == null || relationshipName.isBlank()) {
      return null;
    }
    List<ChildRelationship> known = new ArrayList<>();
    appendKnownChildRelationships(parentType, known);
    String normalizedRelationship = normalize(relationshipName);
    for (ChildRelationship relationship : known) {
      if (relationship == null) {
        continue;
      }
      String candidateName = relationship.getRelationshipName();
      if (candidateName != null && normalize(candidateName).equals(normalizedRelationship)) {
        return relationship;
      }
    }
    return null;
  }

  private static void appendKnownChildRelationships(String parentType, List<ChildRelationship> out) {
    if (parentType == null || parentType.isBlank() || out == null) {
      return;
    }
    if (parentType.equalsIgnoreCase("Contact")) {
      addChildRelationship(out, "Task", "WhoId");
    }
    if (parentType.equalsIgnoreCase("Account")) {
      addChildRelationship(out, "Contact", "AccountId");
      addChildRelationship(out, "Opportunity", "AccountId");
      addChildRelationship(out, "User", "AccountId");
      addChildRelationship(out, "Task", "WhatId");
    }
    if (parentType.equalsIgnoreCase("Contract")) {
      addChildRelationship(out, "Opportunity", "ContractId");
    }
    if (parentType.equalsIgnoreCase("Opportunity")) {
      addChildRelationship(out, "ListEmail", "OpportunityId");
    }
    if (parentType.equalsIgnoreCase("ListEmail")) {
      addChildRelationship(out, "Task", "WhatId");
    }
    if (parentType.equalsIgnoreCase("Case")) {
      addChildRelationship(out, "CaseComment", "ParentId");
    }
  }

  private static void addChildRelationship(
      List<ChildRelationship> out, String childType, String parentLinkField) {
    if (out == null || childType == null || childType.isBlank() || parentLinkField == null || parentLinkField.isBlank()) {
      return;
    }
    ChildRelationship candidate = new ChildRelationship(childType.trim(), parentLinkField.trim());
    for (ChildRelationship existing : out) {
      if (sameRelationship(existing, candidate)) {
        return;
      }
    }
    out.add(candidate);
  }

  private static void register(ObjectDefinition definition) {
    STATE.get().definitions.put(normalize(definition.type), definition);
  }

  private static String normalize(String value) {
    return value.trim().toLowerCase();
  }

  public static final class SObjectTypeNamespace {
    public DescribeSObjectResult get(String typeName) {
      return new DescribeSObjectResult(typeName);
    }

    public DescribeSObjectResult getAs(String typeName) {
      return get(typeName);
    }
  }

  public enum SObjectDescribeOptions {
    DEFERRED,
    FULL
  }

  public static final class DescribeSObjectResult {
    private final String typeName;
    public final FieldNamespace fields;
    public final FieldSetNamespace fieldSets;
    public final String label;

    DescribeSObjectResult(String typeName) {
      this.typeName = typeName == null ? "" : typeName.trim();
      this.fields = new FieldNamespace(this.typeName);
      this.fieldSets = new FieldSetNamespace(this.typeName);
      this.label = this.typeName;
    }

    public boolean isAccessible() {
      if (isMinimumAccessProfile()) {
        // Min access profile restricts standard object access
        String t = typeName.toLowerCase();
        if (t.equals("account") || t.equals("contact") || t.equals("lead")
            || t.equals("opportunity") || t.equals("campaign") || t.equals("case")) {
          // Check if PermissionSet grants Read access
          return ApexStore.hasObjectPermission(typeName, "PermissionsRead");
        }
      }
      return true;
    }

    public boolean isCreateable() {
      if (isMinimumAccessProfile()) {
        String t = typeName.toLowerCase();
        if (t.equals("account") || t.equals("contact") || t.equals("case")
            || t.equals("opportunity") || t.equals("campaign") || t.equals("lead")
            || t.endsWith("__e")) {
          return ApexStore.hasObjectPermission(typeName, "PermissionsCreate");
        }
      }
      return true;
    }

    public boolean isUpdateable() {
      if (isMinimumAccessProfile()) {
        String t = typeName.toLowerCase();
        if (t.equals("account") || t.equals("contact") || t.equals("case")
            || t.equals("opportunity") || t.equals("campaign") || t.equals("lead")) {
          return ApexStore.hasObjectPermission(typeName, "PermissionsEdit");
        }
      }
      return true;
    }

    public boolean IsAccessible() {
      return isAccessible();
    }

    public boolean IsCreateable() {
      return isCreateable();
    }

    public boolean IsUpdateable() {
      return isUpdateable();
    }

    public boolean isDeletable() {
      if (isMinimumAccessProfile()) {
        return ApexStore.hasObjectPermission(typeName, "PermissionsDelete");
      }
      if (isMarketingUserProfile()) {
        String t = typeName.toLowerCase();
        if (t.equals("case")) return false;
      }
      return true;
    }

    public boolean isUndeletable() {
      return isDeletable();
    }

    public boolean isMergeable() {
      return true;
    }

    public boolean isFeedEnabled() {
      return true;
    }

    public boolean isCustomSetting() {
      if (typeName == null || typeName.isBlank()) {
        return false;
      }
      String normalized = typeName.toLowerCase();
      return normalized.endsWith("_settings__c")
          || normalized.endsWith("_settings__mdt")
          || normalized.endsWith("settings__c")
          || normalized.endsWith("settings__mdt");
    }

    private boolean isMinimumAccessProfile() {
      String profileId = CURRENT_PROFILE_ID.get();
      return profileId != null && profileId.equalsIgnoreCase(MINIMUM_ACCESS_PROFILE_ID);
    }

    private boolean isMarketingUserProfile() {
      String profileId = CURRENT_PROFILE_ID.get();
      return profileId != null && profileId.equalsIgnoreCase(MARKETING_USER_PROFILE_ID);
    }

    public String getName() {
      return typeName;
    }

    public String getLocalName() {
      return typeName;
    }

    public String getLabel() {
      return typeName;
    }

    public String getLabelPlural() {
      if (typeName == null || typeName.isBlank()) {
        return "";
      }
      if (typeName.endsWith("y")
          && !typeName.endsWith("ay")
          && !typeName.endsWith("ey")
          && !typeName.endsWith("iy")
          && !typeName.endsWith("oy")
          && !typeName.endsWith("uy")) {
        return typeName.substring(0, typeName.length() - 1) + "ies";
      }
      return typeName + "s";
    }

    public String getKeyPrefix() {
      return Schema.keyPrefixForTypeName(typeName);
    }

    public SObjectType getSObjectType() {
      return new SObjectType(typeName);
    }

    public Map<String, apexemu.runtime.RecordTypeInfo> getRecordTypeInfosById() {
      Map<String, apexemu.runtime.RecordTypeInfo> out = new LinkedHashMap<>();
      for (RecordTypeInfo info : getRecordTypeInfos()) {
        out.put(info.getRecordTypeId(), info);
      }
      return out;
    }

    public Map<String, apexemu.runtime.RecordTypeInfo> getRecordTypeInfosByName() {
      Map<String, apexemu.runtime.RecordTypeInfo> out = new LinkedHashMap<>();
      for (RecordTypeInfo info : getRecordTypeInfos()) {
        out.put(info.getName(), info);
      }
      return out;
    }

    public Map<String, apexemu.runtime.RecordTypeInfo> getRecordTypeInfosByDeveloperName() {
      Map<String, apexemu.runtime.RecordTypeInfo> out = new LinkedHashMap<>();
      for (RecordTypeInfo info : getRecordTypeInfos()) {
        out.put(info.getDeveloperName(), info);
      }
      return out;
    }

    public List<apexemu.runtime.RecordTypeInfo> getRecordTypeInfos() {
      if (typeName == null || typeName.isBlank()) {
        return List.of();
      }
      return new ArrayList<>(DefaultRecordTypeInfo.defaultsFor(typeName));
    }

    public List<ChildRelationship> getChildRelationships() {
      List<ChildRelationship> out = new ArrayList<>();
      if (typeName == null || typeName.isBlank()) {
        return out;
      }
      String normalizedParent = normalize(typeName);
      for (ObjectDefinition definition : STATE.get().definitions.values()) {
        if (definition == null || definition.fields == null || definition.fields.isEmpty()) {
          continue;
        }
        for (FieldDefinition field : definition.fields.values()) {
          if (field == null || field.referenceType == null || field.referenceType.isBlank()) {
            continue;
          }
          if (!normalize(field.referenceType).equals(normalizedParent)) {
            continue;
          }
          addChildRelationship(out, definition.type, field.name);
        }
      }
      appendKnownChildRelationships(typeName, out);
      return out;
    }

    @SuppressWarnings("unchecked")
    public <T extends FieldSetNamespace> T getAs(String field) {
      if (field == null || field.isBlank()) {
        return null;
      }
      if ("fieldsets".equalsIgnoreCase(field)) {
        return (T) new FieldSetNamespace(typeName);
      }
      return null;
    }
  }

  public static final class SObjectType {
    public static final SObjectType Account = new SObjectType("Account");
    public static final SObjectType Contact = new SObjectType("Contact");
    public static final SObjectType Lead = new SObjectType("Lead");
    public static final SObjectType Opportunity = new SObjectType("Opportunity");
    public static final SObjectType OpportunityContactRole = new SObjectType("OpportunityContactRole");
    public static final SObjectType Case = new SObjectType("Case");
    public static final SObjectType Task = new SObjectType("Task");
    public static final SObjectType Event = new SObjectType("Event");
    public static final SObjectType User = new SObjectType("User");
    public static final SObjectType Group = new SObjectType("Group");
    public static final SObjectType CollaborationGroup = new SObjectType("CollaborationGroup");
    public static final SObjectType FeedItem = new SObjectType("FeedItem");
    public static final SObjectType Report = new SObjectType("Report");
    public static final SObjectType AsyncApexJob = new SObjectType("AsyncApexJob");
    public static final SObjectType Campaign = new SObjectType("Campaign");
    public static final SObjectType CampaignMember = new SObjectType("CampaignMember");
    public static final SObjectType Contract = new SObjectType("Contract");
    public static final SObjectType Asset = new SObjectType("Asset");
    public static final SObjectType Product2 = new SObjectType("Product2");
    public static final SObjectType Pricebook2 = new SObjectType("Pricebook2");
    public static final SObjectType PricebookEntry = new SObjectType("PricebookEntry");
    public static final SObjectType OpportunityLineItem = new SObjectType("OpportunityLineItem");
    public static final SObjectType Order = new SObjectType("Order");
    public static final SObjectType OrderItem = new SObjectType("OrderItem");
    public static final SObjectType Quote = new SObjectType("Quote");
    public static final SObjectType QuoteLineItem = new SObjectType("QuoteLineItem");
    public static final SObjectType ContentDocument = new SObjectType("ContentDocument");
    public static final SObjectType ContentDocumentLink = new SObjectType("ContentDocumentLink");
    public static final SObjectType ContentVersion = new SObjectType("ContentVersion");
    public static final SObjectType StaticResource = new SObjectType("StaticResource");
    public static final SObjectType KnowledgeArticleVersion = new SObjectType("KnowledgeArticleVersion");
    public static final SObjectType Profile = new SObjectType("Profile");
    public static final SObjectType PermissionSet = new SObjectType("PermissionSet");
    public static final SObjectType PermissionSetAssignment = new SObjectType("PermissionSetAssignment");
    public static final SObjectType RecordType = new SObjectType("RecordType");

    public final String name;
    public final FieldNamespace fields;
    public final FieldSetNamespace fieldSets;

    public SObjectType(String name) {
      this.name = name == null ? "" : name.trim();
      this.fields = new FieldNamespace(this.name);
      this.fieldSets = new FieldSetNamespace(this.name);
    }

    public DescribeSObjectResult getDescribe() {
      return new DescribeSObjectResult(name);
    }

    public DescribeSObjectResult getDescribe(SObjectDescribeOptions options) {
      return getDescribe();
    }

    public Map<String, apexemu.runtime.RecordTypeInfo> getRecordTypeInfosById() {
      return getDescribe().getRecordTypeInfosById();
    }

    public Map<String, apexemu.runtime.RecordTypeInfo> getRecordTypeInfosByName() {
      return getDescribe().getRecordTypeInfosByName();
    }

    public Map<String, apexemu.runtime.RecordTypeInfo> getRecordTypeInfosByDeveloperName() {
      return getDescribe().getRecordTypeInfosByDeveloperName();
    }

    public List<apexemu.runtime.RecordTypeInfo> getRecordTypeInfos() {
      return getDescribe().getRecordTypeInfos();
    }

    public List<ChildRelationship> getChildRelationships() {
      return getDescribe().getChildRelationships();
    }

    public boolean isAccessible() {
      return getDescribe().isAccessible();
    }

    public boolean isCreateable() {
      return getDescribe().isCreateable();
    }

    public boolean isUpdateable() {
      return getDescribe().isUpdateable();
    }

    public boolean isDeletable() {
      return getDescribe().isDeletable();
    }

    public boolean isUndeletable() {
      return getDescribe().isUndeletable();
    }

    public boolean isMergeable() {
      return getDescribe().isMergeable();
    }

    public boolean isFeedEnabled() {
      return getDescribe().isFeedEnabled();
    }

    public ApexSObject newSObject() {
      return ApexSObject.of(name);
    }

    public ApexSObject newSObject(String recordTypeId) {
      return newSObject();
    }

    public ApexSObject newSObject(String recordTypeId, boolean loadDefaults) {
      ApexSObject row = newSObject();
      if (loadDefaults && name != null && name.toLowerCase().endsWith("__e")) {
        row.set("EventUuid", java.util.UUID.randomUUID().toString());
      }
      return row;
    }

    public String getName() {
      return name;
    }

    public String getLabel() {
      return getDescribe().getLabel();
    }

    public String getLabelPlural() {
      return getDescribe().getLabelPlural();
    }

    public String getKeyPrefix() {
      return getDescribe().getKeyPrefix();
    }

    @SuppressWarnings("unchecked")
    public <T> T getAs(String field) {
      if (field == null || field.isBlank()) {
        return null;
      }
      return (T) new SObjectType(field);
    }

    @Override
    public String toString() {
      return name;
    }

    @Override
    public boolean equals(Object other) {
      if (this == other) {
        return true;
      }
      if (!(other instanceof SObjectType that)) {
        return false;
      }
      return this.name.equalsIgnoreCase(that.name);
    }

    @Override
    public int hashCode() {
      return name.toLowerCase().hashCode();
    }
  }

  public static final class SObjectField {
    private final String ownerType;
    private final String fieldName;

    public SObjectField(String fieldName) {
      this(null, fieldName);
    }

    public SObjectField(String ownerType, String fieldName) {
      this.ownerType = ownerType == null ? "" : ownerType.trim();
      this.fieldName = fieldName == null ? "" : fieldName.trim();
    }

    public DescribeFieldResult getDescribe() {
      return new DescribeFieldResult(ownerType, fieldName);
    }

    public boolean isAccessible() {
      return getDescribe().isAccessible();
    }

    public boolean isCreateable() {
      return getDescribe().isCreateable();
    }

    public boolean isUpdateable() {
      return getDescribe().isUpdateable();
    }

    public boolean isEncrypted() {
      return getDescribe().isEncrypted();
    }

    public boolean isFilterable() {
      return getDescribe().isFilterable();
    }

    public SObjectField getSObjectField() {
      return this;
    }

    public String getLabel() {
      return getDescribe().getLabel();
    }

    public String getName() {
      return fieldName;
    }

    public List<PicklistEntry> getPicklistValues() {
      return getDescribe().getPicklistValues();
    }

    @Override
    public String toString() {
      return fieldName;
    }

    @Override
    public boolean equals(Object other) {
      if (this == other) {
        return true;
      }
      if (!(other instanceof SObjectField that)) {
        return false;
      }
      if (fieldName == null || that.fieldName == null) {
        return fieldName == that.fieldName;
      }
      if (!fieldName.equalsIgnoreCase(that.fieldName)) {
        return false;
      }
      if (ownerType == null || ownerType.isBlank() || that.ownerType == null || that.ownerType.isBlank()) {
        return true;
      }
      return ownerType.equalsIgnoreCase(that.ownerType);
    }

    @Override
    public int hashCode() {
      String normalizedField = fieldName == null ? "" : fieldName.toLowerCase();
      String normalizedOwner = ownerType == null ? "" : ownerType.toLowerCase();
      return 31 * normalizedOwner.hashCode() + normalizedField.hashCode();
    }
  }

  public static final class DescribeFieldResult {
    private final String ownerType;
    private final String fieldName;
    public final String name;
    public final String label;
    public final boolean permissionable;
    public final DisplayType type;
    public final List<SObjectType> referenceTo;

    DescribeFieldResult(String ownerType, String fieldName) {
      this.ownerType = ownerType == null ? "" : ownerType.trim();
      this.fieldName = fieldName == null ? "" : fieldName.trim();
      this.name = canonicalFieldName();
      this.label = this.name == null ? this.fieldName : this.name;
      this.permissionable = true;
      this.referenceTo = resolveReferenceTargets();
      this.type = getType();
    }

    public String getName() {
      return canonicalFieldName();
    }

    public String getLocalName() {
      return canonicalFieldName();
    }

    public String getRelationshipName() {
      if (fieldName.endsWith("Id") && fieldName.length() > 2) {
        return fieldName.substring(0, fieldName.length() - 2);
      }
      if (fieldName.endsWith("__c") && fieldName.length() > 3) {
        return fieldName.substring(0, fieldName.length() - 3) + "__r";
      }
      return fieldName;
    }

    public List<SObjectType> getReferenceTo() {
      if (referenceTo.isEmpty()) {
        return Collections.emptyList();
      }
      return referenceTo;
    }

    public SoapType getSoapType() {
      if (!referenceTo.isEmpty()) {
        return SoapType.ID;
      }
      return SoapType.STRING;
    }

    public SoapType getSOAPType() {
      return getSoapType();
    }

    public DisplayType getType() {
      if (!referenceTo.isEmpty()) {
        return DisplayType.REFERENCE;
      }
      return DisplayType.STRING;
    }

    public List<PicklistEntry> getPicklistValues() {
      // Seed picklist values for well-known NPSP fields.
      if ("Status__c".equalsIgnoreCase(fieldName) && ownerType != null
          && ownerType.toLowerCase().contains("recurring_donation")) {
        return List.of(
            new PicklistEntry("Active", "Active"),
            new PicklistEntry("Lapsed", "Lapsed"),
            new PicklistEntry("Closed", "Closed"),
            new PicklistEntry("Paused", "Paused"),
            new PicklistEntry("Failing", "Failing"));
      }
      return Collections.emptyList();
    }

    public boolean isExternalId() {
      return false;
    }

    public boolean isAutoNumber() {
      return false;
    }

    public Integer getScale() {
      return 0;
    }

    public String getDefaultValueFormula() {
      return null;
    }

    public String getInlineHelpText() {
      return null;
    }

    public Integer getRelationshipOrder() {
      // Relationship fields (lookup/master-detail) return 0 or 1; non-relationship fields return null.
      if (fieldName != null && (fieldName.endsWith("Id") || fieldName.endsWith("__c"))) {
        return 0;
      }
      return null;
    }

    public boolean isNameField() {
      return "Name".equalsIgnoreCase(fieldName);
    }

    public boolean isIdLookup() {
      if (fieldName == null) {
        return false;
      }
      if ("id".equalsIgnoreCase(fieldName) || fieldName.endsWith("Id")) {
        return true;
      }
      return getType() == DisplayType.REFERENCE;
    }

    public boolean isDeprecatedAndHidden() {
      return false;
    }

    public boolean isCustom() {
      if (fieldName == null) {
        return false;
      }
      return fieldName.endsWith("__c") || fieldName.endsWith("__r");
    }

    public boolean isEncrypted() {
      return false;
    }

    public boolean isFilterable() {
      return isAccessible();
    }

    public boolean isAccessible() {
      if (isMinimumAccessProfile()) {
        // Check object-level accessibility first
        DescribeSObjectResult objResult = new DescribeSObjectResult(ownerType);
        if (!objResult.isAccessible()) {
          return false;
        }
        // Min access users: restricted fields unless FieldPermission grants Read
        String f = fieldName.toLowerCase();
        if (isRestrictedFieldForRead(f)) {
          return ApexStore.hasFieldPermission(ownerType, fieldName, "PermissionsRead");
        }
      }
      if (isMarketingUserProfile()) {
        String f = fieldName.toLowerCase();
        if (f.equals("tradestyle")) {
          return false;
        }
      }
      return true;
    }

    public boolean isCreateable() {
      FieldDefinition def = resolveFieldDefinition();
      if (def != null && (def.unique && isAutoNumber())) {
        return false;
      }
      if (isMinimumAccessProfile()) {
        DescribeSObjectResult objResult = new DescribeSObjectResult(ownerType);
        if (!objResult.isCreateable()) {
          return false;
        }
        // Min access: field-level create check
        String f = fieldName.toLowerCase();
        if (isRestrictedFieldForWrite(f)) {
          return ApexStore.hasFieldPermission(ownerType, fieldName, "PermissionsEdit");
        }
      }
      if (isMarketingUserProfile()) {
        String f = fieldName.toLowerCase();
        if (f.equals("tradestyle")) {
          return false;
        }
      }
      return true;
    }

    public boolean isUpdateable() {
      if ("Id".equalsIgnoreCase(fieldName)) {
        return false;
      }
      if (isMinimumAccessProfile()) {
        DescribeSObjectResult objResult = new DescribeSObjectResult(ownerType);
        if (!objResult.isUpdateable()) {
          return false;
        }
        // Min access: field-level edit check
        String f = fieldName.toLowerCase();
        if (isRestrictedFieldForWrite(f)) {
          return ApexStore.hasFieldPermission(ownerType, fieldName, "PermissionsEdit");
        }
      }
      if (isMarketingUserProfile()) {
        String f = fieldName.toLowerCase();
        if (f.equals("tradestyle")) {
          return false;
        }
      }
      return true;
    }

    private static boolean isRestrictedFieldForRead(String fieldLower) {
      return fieldLower.equals("tradestyle") || fieldLower.equals("actualcost")
          || fieldLower.equals("budgetedcost") || fieldLower.equals("title")
          || fieldLower.equals("annualrevenue");
    }

    private static boolean isRestrictedFieldForWrite(String fieldLower) {
      return fieldLower.equals("tradestyle") || fieldLower.equals("title")
          || fieldLower.equals("shippingstreet");
    }

    public boolean isNillable() {
      FieldDefinition def = resolveFieldDefinition();
      if (def != null) {
        return !def.required;
      }
      return true;
    }

    public boolean isRequired() {
      FieldDefinition def = resolveFieldDefinition();
      if (def != null) {
        return def.required;
      }
      return false;
    }

    public boolean isCalculated() {
      return false;
    }

    public boolean isHtmlFormatted() {
      return false;
    }

    public boolean isUnique() {
      FieldDefinition def = resolveFieldDefinition();
      return def != null && def.unique;
    }

    public boolean isSortable() {
      return !isHtmlFormatted();
    }

    public String getLabel() {
      return fieldName;
    }

    public Integer getLength() {
      FieldDefinition def = resolveFieldDefinition();
      if (def != null && def.maxLength != null) {
        return def.maxLength;
      }
      return 255;
    }

    private FieldDefinition resolveFieldDefinition() {
      if (ownerType == null || ownerType.isBlank() || fieldName == null || fieldName.isBlank()) {
        return null;
      }
      ObjectDefinition objDef = Schema.find(ownerType);
      if (objDef == null) {
        return null;
      }
      return objDef.field(fieldName);
    }

    private List<SObjectType> resolveReferenceTargets() {
      FieldDefinition def = resolveFieldDefinition();
      if (def != null && def.referenceType != null && !def.referenceType.isBlank()) {
        return List.of(new SObjectType(def.referenceType));
      }
      if (fieldName == null || fieldName.isBlank()) {
        return Collections.emptyList();
      }
      if (fieldName.equalsIgnoreCase("OwnerId")
          || fieldName.equalsIgnoreCase("CreatedById")
          || fieldName.equalsIgnoreCase("LastModifiedById")
          || fieldName.equalsIgnoreCase("Owner")
          || fieldName.equalsIgnoreCase("CreatedBy")
          || fieldName.equalsIgnoreCase("LastModifiedBy")) {
        return List.of(SObjectType.User);
      }
      if (fieldName.equalsIgnoreCase("ManagerId")) {
        return List.of(SObjectType.User);
      }
      if (fieldName.equalsIgnoreCase("AccountId") || fieldName.equalsIgnoreCase("Account")) {
        return List.of(SObjectType.Account);
      }
      if (fieldName.equalsIgnoreCase("ProfileId")) {
        return List.of(SObjectType.Profile);
      }
      if (fieldName.equalsIgnoreCase("OpportunityId")) {
        return List.of(SObjectType.Opportunity);
      }
      if (fieldName.equalsIgnoreCase("ContractId")) {
        return List.of(SObjectType.Contract);
      }
      if (fieldName.equalsIgnoreCase("ParentId") && ownerType != null && ownerType.equalsIgnoreCase("CaseComment")) {
        return List.of(SObjectType.Case);
      }
      if (fieldName.equalsIgnoreCase("WhatId")) {
        if (ownerType != null && ownerType.equalsIgnoreCase("Task")) {
          return List.of(SObjectType.Account);
        }
      }
      if (fieldName.equalsIgnoreCase("WhoId")) {
        if (ownerType != null && ownerType.equalsIgnoreCase("Task")) {
          return List.of(SObjectType.Contact);
        }
      }
      return Collections.emptyList();
    }

    public SObjectField getSObjectField() {
      return new SObjectField(ownerType, canonicalFieldName());
    }

    public SObjectField getSobjectField() {
      return getSObjectField();
    }

    @SuppressWarnings("unchecked")
    public <T> T getAs(String field) {
      if (field == null || field.isBlank()) {
        return null;
      }
      if ("name".equalsIgnoreCase(field)) {
        return (T) name;
      }
      if ("label".equalsIgnoreCase(field)) {
        return (T) label;
      }
      if ("permissionable".equalsIgnoreCase(field)) {
        return (T) java.lang.Boolean.valueOf(permissionable);
      }
      return null;
    }

    private boolean isMinimumAccessProfile() {
      String profileId = CURRENT_PROFILE_ID.get();
      return profileId != null && profileId.equalsIgnoreCase(MINIMUM_ACCESS_PROFILE_ID);
    }

    private String canonicalFieldName() {
      if (fieldName == null || fieldName.isBlank()) {
        return fieldName;
      }
      FieldDefinition definition = resolveFieldDefinition();
      if (definition != null && definition.name != null && !definition.name.isBlank()) {
        return definition.name;
      }
      if (ownerType == null || ownerType.isBlank()) {
        return fieldName;
      }
      SObjectField token = new FieldNamespace(ownerType).getMap().get(fieldName);
      if (token != null && token.getName() != null && !token.getName().isBlank()) {
        return token.getName();
      }
      return fieldName;
    }

    private boolean isMarketingUserProfile() {
      String profileId = CURRENT_PROFILE_ID.get();
      return profileId != null && profileId.equalsIgnoreCase(MARKETING_USER_PROFILE_ID);
    }
  }

  public static final class FieldNamespace {
    public final SObjectField Id;
    public final SObjectField Name;
    public final SObjectField FirstName;
    public final SObjectField firstName;
    public final SObjectField LastName;
    public final SObjectField lastName;
    public final SObjectField Description;
    public final SObjectField Email;
    public final SObjectField Title;
    public final SObjectField CreatedDate;
    public final SObjectField LastModifiedDate;
    public final SObjectField OwnerId;
    public final SObjectField AccountId;
    public final SObjectField StageName;
    public final SObjectField CloseDate;
    public final SObjectField Amount;

    private final String typeName;

    public FieldNamespace(String typeName) {
      this.typeName = typeName == null ? "" : typeName.trim();
      this.Id = field("Id");
      this.Name = field("Name");
      this.FirstName = field("FirstName");
      this.firstName = field("FirstName");
      this.LastName = field("LastName");
      this.lastName = field("LastName");
      this.Description = field("Description");
      this.Email = field("Email");
      this.Title = field("Title");
      this.CreatedDate = field("CreatedDate");
      this.LastModifiedDate = field("LastModifiedDate");
      this.OwnerId = field("OwnerId");
      this.AccountId = field("AccountId");
      this.StageName = field("StageName");
      this.CloseDate = field("CloseDate");
      this.Amount = field("Amount");
    }

    public SObjectField get(String fieldName) {
      Map<String, SObjectField> fields = getMap();
      SObjectField resolved = fields.get(fieldName);
      if (resolved != null) {
        return resolved;
      }
      return field(fieldName);
    }

    @SuppressWarnings("unchecked")
    public <T> T getAs(String fieldName) {
      return (T) get(fieldName);
    }

    public FieldMap getMap() {
      FieldMap out = new FieldMap(typeName);
      addKnownField(out, Id);
      addSchemaDefinitionFields(out);
      addRuntimeClassFields(out);
      return out;
    }

    private SObjectField field(String fieldName) {
      return new SObjectField(typeName, fieldName);
    }

    private void addKnownField(FieldMap out, SObjectField fieldToken) {
      if (out == null || fieldToken == null) {
        return;
      }
      String fieldName = fieldToken.getName();
      if (fieldName == null || fieldName.isBlank()) {
        return;
      }
      out.putField(fieldName, fieldToken);
    }

    private void addSchemaDefinitionFields(FieldMap out) {
      if (out == null || typeName == null || typeName.isBlank()) {
        return;
      }
      ObjectDefinition definition = Schema.find(typeName);
      if (definition == null || definition.fields == null || definition.fields.isEmpty()) {
        return;
      }
      for (FieldDefinition fieldDefinition : definition.fields.values()) {
        if (fieldDefinition == null || fieldDefinition.name == null || fieldDefinition.name.isBlank()) {
          continue;
        }
        out.putField(fieldDefinition.name, field(fieldDefinition.name));
      }
    }

    private void addRuntimeClassFields(FieldMap out) {
      if (out == null || typeName == null || typeName.isBlank()) {
        return;
      }
      Class<?> runtimeType = resolveRuntimeTypeClass(typeName);
      if (runtimeType == null) {
        return;
      }
      java.lang.reflect.Field[] members = runtimeType.getFields();
      for (java.lang.reflect.Field member : members) {
        if (!Modifier.isStatic(member.getModifiers())) {
          continue;
        }
        if (!SObjectField.class.isAssignableFrom(member.getType())) {
          continue;
        }
        try {
          Object value = member.get(null);
          if (value instanceof SObjectField fieldToken) {
            String fieldName = fieldToken.getName();
            if (fieldName != null && !fieldName.isBlank()) {
              out.putField(fieldName, fieldToken);
            }
          }
        } catch (IllegalAccessException ignored) {
          // best effort: skip inaccessible fields
        }
      }
    }

    private static Class<?> resolveRuntimeTypeClass(String rawTypeName) {
      if (rawTypeName == null || rawTypeName.isBlank()) {
        return null;
      }
      String candidateTypeName = rawTypeName.trim();

      Class<?> runtimeType = tryLoadRuntimeTypeClass(candidateTypeName);
      if (runtimeType != null) {
        return runtimeType;
      }

      ObjectDefinition definition = Schema.find(candidateTypeName);
      if (definition != null && definition.type != null && !definition.type.isBlank()) {
        runtimeType = tryLoadRuntimeTypeClass(definition.type.trim());
        if (runtimeType != null) {
          return runtimeType;
        }
      }

      for (Map.Entry<String, SObjectType> entry : Schema.getGlobalDescribe().entrySet()) {
        if (entry == null) {
          continue;
        }
        String alias = entry.getKey();
        if (alias == null || !alias.equalsIgnoreCase(candidateTypeName)) {
          continue;
        }
        SObjectType token = entry.getValue();
        if (token == null || token.name == null || token.name.isBlank()) {
          continue;
        }
        runtimeType = tryLoadRuntimeTypeClass(token.name.trim());
        if (runtimeType != null) {
          return runtimeType;
        }
      }

      if (!candidateTypeName.isEmpty()) {
        String upperCamel = Character.toUpperCase(candidateTypeName.charAt(0)) + candidateTypeName.substring(1);
        runtimeType = tryLoadRuntimeTypeClass(upperCamel);
        if (runtimeType != null) {
          return runtimeType;
        }
      }

      return null;
    }

    private static Class<?> tryLoadRuntimeTypeClass(String candidateTypeName) {
      if (candidateTypeName == null || candidateTypeName.isBlank()) {
        return null;
      }
      try {
        return Class.forName("apexemu.runtime." + candidateTypeName.trim());
      } catch (ClassNotFoundException | LinkageError ignored) {
        return null;
      }
    }
  }

  public static final class FieldMap extends LinkedHashMap<String, SObjectField> {
    private final String ownerType;
    private final Map<String, String> normalizedToCanonical = new LinkedHashMap<>();

    FieldMap(String ownerType) {
      this.ownerType = ownerType == null ? "" : ownerType.trim();
    }

    void putField(String key, SObjectField value) {
      if (key == null || key.isBlank() || value == null) {
        return;
      }
      String canonical = key.trim();
      String normalized = normalize(canonical);
      String existingCanonical = normalizedToCanonical.get(normalized);
      if (existingCanonical == null) {
        normalizedToCanonical.put(normalized, canonical);
        super.put(canonical, value);
      } else if (!super.containsKey(existingCanonical)) {
        super.put(existingCanonical, value);
      }
    }

    @Override
    public SObjectField get(Object key) {
      SObjectField direct = super.get(key);
      if (direct != null || !(key instanceof String textKey)) {
        return direct;
      }
      if (textKey.isBlank()) {
        return null;
      }
      String normalized = normalize(textKey);
      String canonical = normalizedToCanonical.get(normalized);
      if (canonical != null) {
        return super.get(canonical);
      }
      // Auto-create SObjectField for unknown fields to avoid NPE in callers
      SObjectField autoField = new SObjectField(ownerType, textKey.trim());
      putField(textKey.trim(), autoField);
      return autoField;
    }

    @Override
    public boolean containsKey(Object key) {
      if (super.containsKey(key)) {
        return true;
      }
      if (!(key instanceof String textKey) || textKey.isBlank()) {
        return false;
      }
      return normalizedToCanonical.containsKey(normalize(textKey));
    }

    @Override
    public List<SObjectField> values() {
      return new ArrayList<>(super.values());
    }
  }

  public enum FieldType {
    STRING,
    BOOLEAN,
    INTEGER,
    LONG,
    DECIMAL,
    DOUBLE,
    DATE,
    DATETIME,
    ID
  }

  public static final class PicklistEntry {
    public final String label;
    public final String value;

    public PicklistEntry(String label, String value) {
      this.label = label == null ? "" : label;
      this.value = value == null ? this.label : value;
    }

    public String getLabel() {
      return label;
    }

    public String getValue() {
      return value;
    }

    public boolean isActive() {
      return true;
    }

    public boolean isDefaultValue() {
      return false;
    }
  }

  public enum SoapType {
    BOOLEAN,
    DOUBLE,
    Double,
    INTEGER,
    Integer,
    DATE,
    Date,
    DATETIME,
    DateTime,
    ID,
    STRING
  }

  public enum DisplayType {
    ADDRESS,
    BASE64,
    BOOLEAN,
    CURRENCY,
    Currency,
    REFERENCE,
    Reference,
    STRING,
    String,
    TEXTAREA,
    TextArea,
    DATE,
    Date,
    DateTime,
    DOUBLE,
    Double,
    EMAIL,
    ENCRYPTEDSTRING,
    ID,
    Id,
    Integer,
    JSON,
    LOCATION,
    LONG,
    MULTIPICKLIST,
    PERCENT,
    Percent,
    PHONE,
    PICKLIST,
    Picklist,
    TIME,
    URL
  }

  public static final class DefaultRecordTypeInfo extends ApexSObject implements apexemu.runtime.RecordTypeInfo {
    private static final class Seed {
      final String name;
      final String developerName;
      final boolean defaultMapping;

      Seed(String name, String developerName, boolean defaultMapping) {
        this.name = name;
        this.developerName = developerName;
        this.defaultMapping = defaultMapping;
      }
    }

    public DefaultRecordTypeInfo(
        String typeName,
        String recordTypeId,
        String name,
        String developerName,
        boolean defaultMapping) {
      super("RecordType");
      withId(recordTypeId);
      set("SObjectType", typeName);
      set("RecordTypeId", recordTypeId);
      set("Name", name);
      set("DeveloperName", developerName);
      set("IsAvailable", true);
      set("IsDefaultRecordTypeMapping", defaultMapping);
      set("IsActive", true);
    }

    public DefaultRecordTypeInfo(String typeName, String recordTypeId, String name, String developerName) {
      this(typeName, recordTypeId, name, developerName, true);
    }

    public static DefaultRecordTypeInfo defaultFor(String typeName) {
      List<DefaultRecordTypeInfo> infos = defaultsFor(typeName);
      if (infos.isEmpty()) {
        return masterFor(typeName);
      }
      return infos.get(0);
    }

    public static List<DefaultRecordTypeInfo> defaultsFor(String typeName) {
      String canonicalType = canonicalType(typeName);
      List<DefaultRecordTypeInfo> out = new ArrayList<>();
      for (Seed seed : seedsFor(canonicalType)) {
        out.add(
            new DefaultRecordTypeInfo(
                canonicalType,
                recordTypeIdFor(canonicalType, seed.developerName),
                seed.name,
                seed.developerName,
                seed.defaultMapping));
      }
      out.add(masterFor(canonicalType));
      return out;
    }

    public static DefaultRecordTypeInfo masterFor(String typeName) {
      String canonicalType = canonicalType(typeName);
      return new DefaultRecordTypeInfo(
          canonicalType,
          recordTypeIdFor(canonicalType, "Master"),
          "Master",
          "Master",
          false);
    }

    private static String canonicalType(String typeName) {
      return typeName == null || typeName.isBlank() ? "SObject" : typeName.trim();
    }

    private static List<Seed> seedsFor(String typeName) {
      String normalized = typeName == null ? "" : typeName.trim().toLowerCase(Locale.ROOT);
      if ("account".equals(normalized)) {
        return List.of(
            new Seed("Organization", "Organization", true),
            new Seed("Household", "HH_Account", false),
            new Seed("One to One", "One_to_One", false),
            new Seed("One to One Account", "One_to_One_Account", false));
      }
      if ("opportunity".equals(normalized)) {
        return List.of(
            new Seed("Donation", "Donation", true),
            new Seed("Membership", "Membership", false));
      }
      if ("contact".equals(normalized)) {
        return List.of(new Seed("Individual", "Individual", true));
      }
      return List.of(new Seed("Default", "Default", true));
    }

    private static String recordTypeIdFor(String typeName, String developerName) {
      String typeToken = typeName == null ? "" : typeName.trim().toLowerCase(Locale.ROOT);
      String developerToken =
          developerName == null ? "" : developerName.trim().toLowerCase(Locale.ROOT);
      long hash = Integer.toUnsignedLong((typeToken + "#" + developerToken).hashCode());
      return String.format(Locale.ROOT, "012%012dAAA", hash % 1_000_000_000_000L);
    }

    @Override
    public ApexSObject getRecordTypeInfo() {
      return this;
    }

    @Override
    public String getRecordTypeId() {
      return super.getRecordTypeId();
    }

    @Override
    public boolean isAvailable() {
      return super.isAvailable();
    }

    @Override
    public boolean isDefaultRecordTypeMapping() {
      return super.isDefaultRecordTypeMapping();
    }

    @Override
    public String getName() {
      Object value = get("Name");
      return value == null ? null : String.valueOf(value);
    }

    @Override
    public String getDeveloperName() {
      return super.getDeveloperName();
    }

    @Override
    public boolean isMaster() {
      return super.isMaster();
    }
  }

  public static final class FieldSetMember {
    private final String ownerType;
    public final String fieldPath;

    public FieldSetMember(String fieldPath) {
      this("", fieldPath);
    }

    public FieldSetMember(String ownerType, String fieldPath) {
      this.ownerType = ownerType == null ? "" : ownerType.trim();
      this.fieldPath = fieldPath == null ? "" : fieldPath.trim();
    }

    public String getFieldPath() {
      return fieldPath;
    }

    public Boolean getDbRequired() {
      return false;
    }

    public Boolean getRequired() {
      return false;
    }

    public DisplayType getType() {
      return getSObjectField().getDescribe().getType();
    }

    public SObjectField getSObjectField() {
      if (fieldPath == null || fieldPath.isBlank()) {
        return new SObjectField(ownerType, "");
      }
      String leaf = fieldPath;
      int dot = leaf.lastIndexOf('.');
      if (dot >= 0 && dot + 1 < leaf.length()) {
        leaf = leaf.substring(dot + 1);
      }
      return new SObjectField(ownerType, leaf);
    }

    public SObjectField getSobjectField() {
      return getSObjectField();
    }
  }

  public static final class FieldSet {
    private final String sObjectType;
    private final String name;
    private final List<FieldSetMember> fields;

    public FieldSet() {
      this("", "", new ArrayList<>());
    }

    public FieldSet(List<FieldSetMember> fields) {
      this("", "", fields);
    }

    public FieldSet(String sObjectType, String name, List<FieldSetMember> fields) {
      this.sObjectType = sObjectType == null ? "" : sObjectType.trim();
      this.name = name == null ? "" : name.trim();
      this.fields = fields == null ? new ArrayList<>() : new ArrayList<>(fields);
    }

    public List<FieldSetMember> getFields() {
      return new ArrayList<>(fields);
    }

    public String getName() {
      return name;
    }

    public SObjectType getSObjectType() {
      if (sObjectType == null || sObjectType.isBlank()) {
        return null;
      }
      return new SObjectType(sObjectType);
    }
  }

  public static final class FieldSetNamespace {
    private final String typeName;

    public FieldSetNamespace(String typeName) {
      this.typeName = typeName == null ? "" : typeName.trim();
    }

    public FieldSet get(String fieldSetName) {
      if (fieldSetName == null || fieldSetName.isBlank()) {
        return new FieldSet(typeName, "", new ArrayList<>());
      }
      Map<String, FieldSet> registry = STATE.get().fieldSets.get(normalize(typeName));
      if (registry == null || registry.isEmpty()) {
        return new FieldSet(typeName, fieldSetName, new ArrayList<>());
      }
      FieldSet fieldSet = registry.get(normalize(fieldSetName));
      if (fieldSet != null) {
        return fieldSet;
      }
      return new FieldSet(typeName, fieldSetName, new ArrayList<>());
    }

    @SuppressWarnings("unchecked")
    public <T> T getAs(String fieldSetName) {
      return (T) get(fieldSetName);
    }

    public Map<String, FieldSet> getMap() {
      Map<String, FieldSet> registry = STATE.get().fieldSets.get(normalize(typeName));
      if (registry == null || registry.isEmpty()) {
        return new LinkedHashMap<>();
      }
      return new LinkedHashMap<>(registry);
    }

    @Override
    public String toString() {
      return typeName + ".FieldSets";
    }
  }

  public static final class ObjectBuilder {
    private final String type;
    private final Map<String, FieldDefinition> fields = new LinkedHashMap<>();

    private ObjectBuilder(String type) {
      if (type == null || type.isBlank()) {
        throw new IllegalArgumentException("sobject type cannot be blank");
      }
      this.type = type.trim();
    }

    public ObjectBuilder required(String field, FieldType type) {
      return define(field, type, true);
    }

    public ObjectBuilder optional(String field, FieldType type) {
      return define(field, type, false);
    }

    public ObjectBuilder requiredPicklist(String field, String... values) {
      return define(field, FieldType.STRING, true).picklist(field, values);
    }

    public ObjectBuilder optionalPicklist(String field, String... values) {
      return define(field, FieldType.STRING, false).picklist(field, values);
    }

    public ObjectBuilder define(String field, FieldType type, boolean required) {
      if (field == null || field.isBlank()) {
        throw new IllegalArgumentException("field cannot be blank");
      }
      if (type == null) {
        throw new IllegalArgumentException("field type cannot be null");
      }
      String canonical = field.trim();
      fields.put(
          normalize(canonical),
          new FieldDefinition(
              canonical, type, required, null, Set.of(), null, null, null, false, false, null));
      return this;
    }

    public ObjectBuilder maxLength(String field, int maxLength) {
      if (maxLength <= 0) {
        throw new IllegalArgumentException("maxLength must be positive");
      }
      FieldDefinition existing = requireDefinedField(field);
      if (existing.type != FieldType.STRING && existing.type != FieldType.ID) {
        throw new IllegalArgumentException(
            "maxLength can be applied only to STRING/ID fields: " + existing.name);
      }
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              Integer.valueOf(maxLength),
              existing.picklistValues,
              existing.precision,
              existing.scale,
              existing.referenceType,
              existing.unique,
              existing.externalId,
              existing.childRelationshipName));
      return this;
    }

    public ObjectBuilder picklist(String field, String... values) {
      FieldDefinition existing = requireDefinedField(field);
      if (existing.type != FieldType.STRING) {
        throw new IllegalArgumentException("picklist can be applied only to STRING fields: " + existing.name);
      }
      Set<String> picklistValues = normalizePicklist(values);
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              existing.maxLength,
              picklistValues,
              existing.precision,
              existing.scale,
              existing.referenceType,
              existing.unique,
              existing.externalId,
              existing.childRelationshipName));
      return this;
    }

    public ObjectBuilder precision(String field, int precision, int scale) {
      if (precision <= 0) {
        throw new IllegalArgumentException("precision must be positive");
      }
      if (scale < 0) {
        throw new IllegalArgumentException("scale cannot be negative");
      }
      if (scale > precision) {
        throw new IllegalArgumentException("scale cannot exceed precision");
      }
      FieldDefinition existing = requireDefinedField(field);
      if (existing.type != FieldType.DECIMAL
          && existing.type != FieldType.DOUBLE
          && existing.type != FieldType.INTEGER
          && existing.type != FieldType.LONG) {
        throw new IllegalArgumentException(
            "precision can be applied only to numeric fields: " + existing.name);
      }
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              existing.maxLength,
              existing.picklistValues,
              Integer.valueOf(precision),
              Integer.valueOf(scale),
              existing.referenceType,
              existing.unique,
              existing.externalId,
              existing.childRelationshipName));
      return this;
    }

    public ObjectBuilder reference(String field, String referenceType) {
      return reference(field, referenceType, null);
    }

    public ObjectBuilder reference(String field, String referenceType, String childRelationshipName) {
      if (referenceType == null || referenceType.isBlank()) {
        throw new IllegalArgumentException("referenceType cannot be blank");
      }
      FieldDefinition existing = requireDefinedField(field);
      if (existing.type != FieldType.ID) {
        throw new IllegalArgumentException("reference can be applied only to ID fields: " + existing.name);
      }
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              existing.maxLength,
              existing.picklistValues,
              existing.precision,
              existing.scale,
              referenceType.trim(),
              existing.unique,
              existing.externalId,
              normalizeBlank(childRelationshipName)));
      return this;
    }

    public ObjectBuilder unique(String field) {
      FieldDefinition existing = requireDefinedField(field);
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              existing.maxLength,
              existing.picklistValues,
              existing.precision,
              existing.scale,
              existing.referenceType,
              true,
              existing.externalId,
              existing.childRelationshipName));
      return this;
    }

    public ObjectBuilder externalId(String field) {
      FieldDefinition existing = requireDefinedField(field);
      if (!supportsExternalIdType(existing.type)) {
        throw new IllegalArgumentException("externalId is not supported for field type: " + existing.type);
      }
      fields.put(
          normalize(existing.name),
          new FieldDefinition(
              existing.name,
              existing.type,
              existing.required,
              existing.maxLength,
              existing.picklistValues,
              existing.precision,
              existing.scale,
              existing.referenceType,
              existing.unique,
              true,
              existing.childRelationshipName));
      return this;
    }

    private FieldDefinition requireDefinedField(String field) {
      if (field == null || field.isBlank()) {
        throw new IllegalArgumentException("field cannot be blank");
      }
      String normalized = normalize(field.trim());
      FieldDefinition existing = fields.get(normalized);
      if (existing == null) {
        throw new IllegalArgumentException("field must be defined before applying constraints: " + field);
      }
      return existing;
    }

    private static Set<String> normalizePicklist(String... values) {
      if (values == null || values.length == 0) {
        throw new IllegalArgumentException("picklist values cannot be empty");
      }
      Set<String> out = new LinkedHashSet<>();
      for (String value : values) {
        if (value == null || value.isBlank()) {
          throw new IllegalArgumentException("picklist value cannot be blank");
        }
        out.add(value.trim());
      }
      if (out.isEmpty()) {
        throw new IllegalArgumentException("picklist values cannot be empty");
      }
      return Set.copyOf(out);
    }

    private static boolean supportsExternalIdType(FieldType type) {
      return type == FieldType.STRING
          || type == FieldType.ID
          || type == FieldType.INTEGER
          || type == FieldType.LONG
          || type == FieldType.DECIMAL
          || type == FieldType.DOUBLE;
    }

    private static String normalizeBlank(String value) {
      if (value == null || value.isBlank()) {
        return null;
      }
      return value.trim();
    }

    public void register() {
      Schema.register(new ObjectDefinition(type, Map.copyOf(fields)));
    }
  }

  static final class ObjectDefinition {
    final String type;
    final Map<String, FieldDefinition> fields;

    ObjectDefinition(String type, Map<String, FieldDefinition> fields) {
      this.type = type;
      this.fields = fields;
    }

    FieldDefinition field(String field) {
      if (field == null || field.isBlank()) {
        return null;
      }
      return fields.get(normalize(field));
    }
  }

  static final class FieldDefinition {
    final String name;
    final FieldType type;
    final boolean required;
    final Integer maxLength;
    final Set<String> picklistValues;
    final Integer precision;
    final Integer scale;
    final String referenceType;
    final boolean unique;
    final boolean externalId;
    final String childRelationshipName;

    FieldDefinition(
        String name,
        FieldType type,
        boolean required,
        Integer maxLength,
        Set<String> picklistValues,
        Integer precision,
        Integer scale,
        String referenceType,
        boolean unique,
        boolean externalId,
        String childRelationshipName) {
      this.name = name;
      this.type = type;
      this.required = required;
      this.maxLength = maxLength;
      this.picklistValues = picklistValues == null ? Set.of() : picklistValues;
      this.precision = precision;
      this.scale = scale;
      this.referenceType = referenceType;
      this.unique = unique;
      this.externalId = externalId;
      this.childRelationshipName = childRelationshipName;
    }
  }

  public static final class ChildRelationship {
    final String childType;
    final String parentLinkField;

    ChildRelationship(String childType, String parentLinkField) {
      this.childType = childType;
      this.parentLinkField = parentLinkField;
    }

    public SObjectType getChildSObject() {
      return new SObjectType(childType);
    }

    public String getField() {
      return parentLinkField;
    }

    public String getRelationshipName() {
      if (childType == null || childType.isBlank()) {
        return "";
      }
      String plural = pluralizeTypeName(childType);
      return plural == null ? "" : plural;
    }

    @Override
    public boolean equals(Object other) {
      if (this == other) {
        return true;
      }
      if (!(other instanceof ChildRelationship that)) {
        return false;
      }
      return sameRelationship(this, that);
    }

    @Override
    public int hashCode() {
      String normalizedChild = childType == null || childType.isBlank() ? "" : normalize(childType);
      String normalizedField = parentLinkField == null || parentLinkField.isBlank() ? "" : normalize(parentLinkField);
      return 31 * normalizedChild.hashCode() + normalizedField.hashCode();
    }
  }

  /** Register default standard object schemas with common required fields. */
  public static void registerStandardDefaults() {
    object("Account")
        .required("Name", FieldType.STRING)
        .optional("AccountNumber", FieldType.STRING)
        .optional("AnnualRevenue", FieldType.DECIMAL)
        .optional("Type", FieldType.STRING)
        .optional("Description", FieldType.STRING)
        .optional("Rating", FieldType.STRING)
        .optional("ShippingStreet", FieldType.STRING)
        .optional("ShippingCountry", FieldType.STRING)
        .optional("ParentId", FieldType.ID)
        .reference("ParentId", "Account")
        .optional("OwnerId", FieldType.ID)
        .reference("OwnerId", "User")
        .optional("CreatedById", FieldType.ID)
        .reference("CreatedById", "User")
        .register();
    object("Contact")
        .required("LastName", FieldType.STRING)
        .optional("FirstName", FieldType.STRING)
        .optional("AccountId", FieldType.ID)
        .reference("AccountId", "Account", "Contacts")
        .optional("Email", FieldType.STRING)
        .optional("Title", FieldType.STRING)
        .optional("HomePhone", FieldType.STRING)
        .optional("Fax", FieldType.STRING)
        .optional("OwnerId", FieldType.ID)
        .reference("OwnerId", "User")
        .optional("CreatedById", FieldType.ID)
        .reference("CreatedById", "User")
        .optional("LastModifiedById", FieldType.ID)
        .reference("LastModifiedById", "User")
        .optional("Birthdate", FieldType.DATE)
        .optional("Description", FieldType.STRING)
        .register();
    object("Opportunity")
        .required("Name", FieldType.STRING)
        .required("StageName", FieldType.STRING)
        .required("CloseDate", FieldType.DATE)
        .optional("Amount", FieldType.DECIMAL)
        .optional("Type", FieldType.STRING)
        .optional("Description", FieldType.STRING)
        .optional("ExpectedRevenue", FieldType.DECIMAL)
        .optional("AccountId", FieldType.ID)
        .reference("AccountId", "Account", "Opportunities")
        .optional("Pricebook2Id", FieldType.ID)
        .reference("Pricebook2Id", "Pricebook2")
        .optional("Probability", FieldType.DECIMAL)
        .optional("DiscountType__c", FieldType.STRING)
        .optional("InvoicedStatus__c", FieldType.STRING)
        .register();
    object("OpportunityLineItem")
        .optional("Description", FieldType.STRING)
        .optional("ListPrice", FieldType.DECIMAL)
        .required("OpportunityId", FieldType.ID)
        .reference("OpportunityId", "Opportunity", "OpportunityLineItems")
        .optional("PricebookEntryId", FieldType.ID)
        .reference("PricebookEntryId", "PricebookEntry")
        .optional("Quantity", FieldType.DECIMAL)
        .optional("SortOrder", FieldType.INTEGER)
        .optional("TotalPrice", FieldType.DECIMAL)
        .optional("UnitPrice", FieldType.DECIMAL)
        .register();
    object("PricebookEntry")
        .optional("Name", FieldType.STRING)
        .optional("IsActive", FieldType.BOOLEAN)
        .optional("Product2Id", FieldType.ID)
        .reference("Product2Id", "Product2")
        .optional("Pricebook2Id", FieldType.ID)
        .reference("Pricebook2Id", "Pricebook2")
        .optional("ProductCode", FieldType.STRING)
        .optional("UnitPrice", FieldType.DECIMAL)
        .optional("UseStandardPrice", FieldType.BOOLEAN)
        .register();
    object("Pricebook2")
        .optional("Name", FieldType.STRING)
        .optional("Description", FieldType.STRING)
        .optional("IsActive", FieldType.BOOLEAN)
        .optional("IsStandard", FieldType.BOOLEAN)
        .register();
    object("Product2")
        .optional("Name", FieldType.STRING)
        .optional("Description", FieldType.STRING)
        .optional("IsActive", FieldType.BOOLEAN)
        .optional("ProductCode", FieldType.STRING)
        .optional("SubscriberField__c", FieldType.STRING)
        .optional("DiscountingApproved__c", FieldType.BOOLEAN)
        .register();
    object("Lead")
        .optional("FirstName", FieldType.STRING)
        .required("LastName", FieldType.STRING)
        .required("Company", FieldType.STRING)
        .register();
    object("Task")
        .optional("Subject", FieldType.STRING)
        .optional("WhoId", FieldType.ID)
        .reference("WhoId", "Contact", "Tasks")
        .optional("WhatId", FieldType.ID)
        .reference("WhatId", "Account", "Tasks")
        .register();
    object("Case")
        .optional("Subject", FieldType.STRING)
        .optional("OwnerId", FieldType.ID)
        .reference("OwnerId", "User")
        .register();
    object("CaseComment")
        .optional("CommentBody", FieldType.STRING)
        .optional("CreatedDate", FieldType.DATETIME)
        .optional("ParentId", FieldType.ID)
        .reference("ParentId", "Case", "CaseComments")
        .register();
    object("User")
        .optional("FirstName", FieldType.STRING)
        .optional("LastName", FieldType.STRING)
        .optional("Username", FieldType.STRING)
        .optional("Email", FieldType.STRING)
        .optional("LastLoginDate", FieldType.DATETIME)
        .optional("ProfileId", FieldType.ID)
        .reference("ProfileId", "Profile")
        .optional("ManagerId", FieldType.ID)
        .reference("ManagerId", "User")
        .optional("CreatedById", FieldType.ID)
        .reference("CreatedById", "User")
        .optional("LastModifiedById", FieldType.ID)
        .reference("LastModifiedById", "User")
        .optional("UserRoleId", FieldType.ID)
        .register();
    object("Contract")
        .optional("ContractNumber", FieldType.STRING)
        .optional("AccountId", FieldType.ID)
        .reference("AccountId", "Account", "Contracts")
        .register();
    object("ListEmail")
        .optional("Name", FieldType.STRING)
        .optional("OpportunityId", FieldType.ID)
        .reference("OpportunityId", "Opportunity", "ListEmails")
        .register();
    object("DeveloperWorkItem__c")
        .optional("CodingHours__c", FieldType.INTEGER)
        .optional("CodeReviewingHours__c", FieldType.INTEGER)
        .optional("TechnicalDesignHours__c", FieldType.INTEGER)
        .optional("DeveloperCost__c", FieldType.INTEGER)
        .optional("WorkOrder__c", FieldType.ID)
        .reference("WorkOrder__c", "WorkOrder__c")
        .register();
    object("Invoice__c")
        .optional("Account__c", FieldType.ID)
        .reference("Account__c", "Account")
        .optional("Opportunity__c", FieldType.ID)
        .reference("Opportunity__c", "Opportunity")
        .optional("Amount__c", FieldType.DECIMAL)
        .optional("InvoiceDate__c", FieldType.DATE)
        .optional("Description__c", FieldType.STRING)
        .optional("Dispatched__c", FieldType.BOOLEAN)
        .optional("Paid__c", FieldType.BOOLEAN)
        .optional("Reference__c", FieldType.STRING)
        .optional("ChatterAPIHeader__c", FieldType.STRING)
        .register();
    object("InvoiceLine__c")
        .optional("Invoice__c", FieldType.ID)
        .reference("Invoice__c", "Invoice__c")
        .optional("Description__c", FieldType.STRING)
        .optional("LineTotal__c", FieldType.DECIMAL)
        .optional("Product__c", FieldType.ID)
        .reference("Product__c", "Product2")
        .optional("Quantity__c", FieldType.DECIMAL)
        .optional("UnitPrice__c", FieldType.DECIMAL)
        .register();
    object("OpportunitySettings__c")
        .optional("DiscountType__c", FieldType.STRING)
        .register();
    object("WorkOrder__c").register();
    registerFieldSet("Product2", "OpportunityDiscount", "SubscriberField__c");
  }

  private static final class State {
    final Map<String, ObjectDefinition> definitions = new LinkedHashMap<>();
    final Map<String, Map<String, FieldSet>> fieldSets = new LinkedHashMap<>();
  }
}
