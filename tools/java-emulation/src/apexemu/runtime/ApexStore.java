package apexemu.runtime;

import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.regex.PatternSyntaxException;

final class ApexStore {
  private static final String IDENTIFIER_TEXT = "[a-zA-Z_][\\w]*";
  private static final String FIELD_PATH_TEXT = IDENTIFIER_TEXT + "(?:\\." + IDENTIFIER_TEXT + ")*";
  private static final String DATE_PART_FUNCTION_TEXT = "calendar_year";
  private static final Pattern FROM_PATTERN =
      Pattern.compile("(?i)\\bfrom\\s+(" + FIELD_PATH_TEXT + ")");
  private static final Pattern LIMIT_PATTERN = Pattern.compile("(?i)\\blimit\\s+(\\d+)");
  private static final Pattern OFFSET_PATTERN = Pattern.compile("(?i)\\boffset\\s+(\\d+)");
  private static final Pattern WHERE_KEYWORD = Pattern.compile("(?i)\\bwhere\\b");
  private static final Pattern GROUP_BY_KEYWORD = Pattern.compile("(?i)\\bgroup\\s+by\\b");
  private static final Pattern HAVING_KEYWORD = Pattern.compile("(?i)\\bhaving\\b");
  private static final Pattern WHERE_PATTERN =
      Pattern.compile("(?i)^(" + FIELD_PATH_TEXT + ")\\s*(>=|<=|!=|=|>|<)\\s*(.+)$");
  private static final Pattern WHERE_IN_PATTERN =
      Pattern.compile("(?i)^(" + FIELD_PATH_TEXT + ")\\s+(not\\s+in|in)\\s*\\((.*)\\)$");
  private static final Pattern WHERE_IN_BIND_PATTERN =
      Pattern.compile("(?i)^(" + FIELD_PATH_TEXT + ")\\s+(not\\s+in|in)\\s*(:[a-zA-Z_][\\w.]*)$");
  private static final Pattern WHERE_LIKE_PATTERN =
      Pattern.compile("(?i)^(" + FIELD_PATH_TEXT + ")\\s+like\\s+(.+)$");
  private static final Pattern WHERE_NULL_PATTERN =
      Pattern.compile("(?i)^(" + FIELD_PATH_TEXT + ")\\s+is\\s+(not\\s+)?null$");
  private static final Pattern ORDER_BY_KEYWORD = Pattern.compile("(?i)\\border\\s+by\\b");
  private static final Pattern TRAILING_FOR_UPDATE_PATTERN =
      Pattern.compile("(?i)\\s+for\\s+update\\s*$");
  private static final Pattern TRAILING_FOR_VIEW_PATTERN =
      Pattern.compile("(?i)\\s+for\\s+view\\s*$");
  private static final Pattern TRAILING_FOR_REFERENCE_PATTERN =
      Pattern.compile("(?i)\\s+for\\s+reference\\s*$");
  private static final Pattern TRAILING_ALL_ROWS_PATTERN =
      Pattern.compile("(?i)\\s+all\\s+rows\\s*$");
  private static final Pattern INLINE_WITH_MODE_PATTERN =
      Pattern.compile("(?i)\\s+with\\s+(user_mode|system_mode|security_enforced)\\b");
  private static final Pattern ORDER_BY_PATTERN =
      Pattern.compile(
          "(?i)^(" + FIELD_PATH_TEXT + "|\\w+\\([^)]*\\))(?:\\s+(asc|desc))?(?:\\s+nulls\\s+(first|last))?$");
  private static final Pattern IDENTIFIER_PATTERN = Pattern.compile("(?i)^" + IDENTIFIER_TEXT + "$");
  private static final Pattern FIELD_PATH_PATTERN = Pattern.compile("(?i)^" + FIELD_PATH_TEXT + "$");
  private static final Pattern SELECT_AGGREGATE_PATTERN =
      Pattern.compile(
          "(?i)^(count_distinct|count|sum|avg|min|max)\\s*\\(\\s*(\\*|"
              + FIELD_PATH_TEXT
              + ")?\\s*\\)(?:\\s+(?:as\\s+)?("
              + IDENTIFIER_TEXT
              + "))?$");
  private static final Pattern SELECT_FIELD_PATTERN =
      Pattern.compile(
          "(?i)^("
              + FIELD_PATH_TEXT
              + ")(?:\\s+(?:as\\s+)?("
              + IDENTIFIER_TEXT
              + "))?$");
  private static final Pattern SELECT_DATE_PART_FIELD_PATTERN =
      Pattern.compile(
          "(?i)^("
              + DATE_PART_FUNCTION_TEXT
              + ")\\s*\\(\\s*("
              + FIELD_PATH_TEXT
              + ")\\s*\\)(?:\\s+(?:as\\s+)?("
              + IDENTIFIER_TEXT
              + "))?$");
  private static final Pattern DATE_PART_FIELD_PATTERN =
      Pattern.compile(
          "(?i)^("
              + DATE_PART_FUNCTION_TEXT
              + ")\\s*\\(\\s*("
              + FIELD_PATH_TEXT
              + ")\\s*\\)$");
  private static final Pattern HAVING_CLAUSE_PATTERN =
      Pattern.compile("(?i)^(.+?)\\s*(>=|<=|!=|=|>|<)\\s*(.+)$");
  private static final Pattern HAVING_AGGREGATE_OPERAND_PATTERN =
      Pattern.compile(
          "(?i)^(count_distinct|count|sum|avg|min|max)\\s*\\(\\s*(\\*|"
              + FIELD_PATH_TEXT
              + ")?\\s*\\)$");
  private static final Pattern SOSL_PATTERN =
      Pattern.compile("(?is)^find\\s+(.+?)\\s+in\\s+(all|name)\\s+fields\\s+returning\\s+(.+)$");
  private static final Pattern RELATIVE_N_DAYS_LITERAL_PATTERN =
      Pattern.compile("(?i)^(last_n_days|next_n_days|n_days_ago):(\\d+)$");
  private static final Clock SOQL_CLOCK = Clock.systemUTC();
  private static final ThreadLocal<State> STATE = ThreadLocal.withInitial(ApexStore::seededState);
  private static final ThreadLocal<RuntimeConfig> CONFIG = ThreadLocal.withInitial(RuntimeConfig::new);

  private ApexStore() {}

  static void reset() {
    STATE.set(seededState());
  }

  private static State seededState() {
    State state = new State();
    seedProfile(
        state,
        "00e000000000001",
        "Minimum Access - Salesforce",
        "Standard",
        Boolean.FALSE,
        Boolean.TRUE,
        Boolean.TRUE);
    seedProfile(
        state,
        "00e000000000002",
        "System Administrator",
        "Standard",
        Boolean.TRUE,
        Boolean.TRUE,
        Boolean.TRUE);
    seedProfile(
        state,
        "00e000000000003",
        "Standard User",
        "Standard",
        Boolean.TRUE,
        Boolean.TRUE,
        Boolean.TRUE);
    seedProfile(
        state,
        "00e000000000004",
        "Marketing User",
        "Standard",
        Boolean.TRUE,
        Boolean.TRUE,
        Boolean.TRUE);
    seedPermissionSet(state, "0PS000000000001", "dreamhouse");
    seedPermissionSet(state, "0PS000000000002", "Proving_With_User_Mode_Works");
    seedPermissionSet(state, "0PS000000000003", "provides_access_to_actual_cost_field_on_campaign");
    seedPermissionSet(state, "0PS000000000004", "Provides_Read_Only_Access_to_Account_and_all_fields");
    seedPermissionSet(state, "0PS000000000005", "Provides_Read_Access_to_Contact_and_Contact_Name_field");
    seedPermissionSet(state, "0PS000000000006", "Provides_create_access_to_Contact_and_contact_email_field");
    seedPermissionSet(state, "0PS000000000007", "Provides_edit_access_to_Accounts_except_shippingStreet");
    seedPermissionSet(state, "0PS000000000008", "Read_access_to_Account_Shipping_Address");
    seedPermissionSet(state, "0PS000000000009", "ReadAccessToTradeStyle");
    seedPermissionSetGroup(
        state,
        "0PG000000000001",
        "Permission_Set_Group_for_testing",
        "Updated");
    seedObjectPermission(
        state,
        "0OP000000000001",
        "0PS000000000002",
        "Account",
        Boolean.TRUE,
        Boolean.FALSE,
        Boolean.FALSE,
        Boolean.FALSE);
    seedObjectPermission(
        state,
        "0OP000000000002",
        "0PS000000000003",
        "Campaign",
        Boolean.TRUE,
        Boolean.FALSE,
        Boolean.FALSE,
        Boolean.FALSE);
    seedObjectPermission(
        state,
        "0OP000000000003",
        "0PS000000000004",
        "Account",
        Boolean.TRUE,
        Boolean.FALSE,
        Boolean.FALSE,
        Boolean.FALSE);
    seedObjectPermission(
        state,
        "0OP000000000004",
        "0PS000000000005",
        "Contact",
        Boolean.TRUE,
        Boolean.FALSE,
        Boolean.FALSE,
        Boolean.FALSE);
    seedObjectPermission(
        state,
        "0OP000000000005",
        "0PS000000000006",
        "Contact",
        Boolean.TRUE,
        Boolean.TRUE,
        Boolean.FALSE,
        Boolean.FALSE);
    seedObjectPermission(
        state,
        "0OP000000000006",
        "0PS000000000007",
        "Account",
        Boolean.TRUE,
        Boolean.FALSE,
        Boolean.TRUE,
        Boolean.FALSE);
    seedObjectPermission(
        state,
        "0OP000000000007",
        "0PS000000000008",
        "Account",
        Boolean.TRUE,
        Boolean.FALSE,
        Boolean.FALSE,
        Boolean.FALSE);
    seedFieldPermission(
        state,
        "0FP000000000001",
        "0PS000000000003",
        "Campaign.ActualCost",
        Boolean.TRUE,
        Boolean.FALSE);
    seedFieldPermission(
        state,
        "0FP000000000002",
        "0PS000000000005",
        "Contact.AccountId",
        Boolean.TRUE,
        Boolean.FALSE);
    seedFieldPermission(
        state,
        "0FP000000000003",
        "0PS000000000006",
        "Contact.AccountId",
        Boolean.TRUE,
        Boolean.TRUE);
    seedFieldPermission(
        state,
        "0FP000000000004",
        "0PS000000000006",
        "Contact.Email",
        Boolean.TRUE,
        Boolean.TRUE);
    seedFieldPermission(
        state,
        "0FP000000000005",
        "0PS000000000007",
        "Account.ShippingStreet",
        Boolean.TRUE,
        Boolean.TRUE);
    seedFieldPermission(
        state,
        "0FP000000000006",
        "0PS000000000008",
        "Account.ShippingStreet",
        Boolean.TRUE,
        Boolean.FALSE);
    seedFieldPermission(
        state,
        "0FP000000000007",
        "0PS000000000009",
        "Account.TradeStyle",
        Boolean.TRUE,
        Boolean.FALSE);
    seedPlatformCachePartition(state, "08A000000000001", "default", "");
    seedOrganization(state, "00D000000000001", "ApexGov Test Org");
    seedStandardPricebook(state, "01s000000000001AAA");
    seedCustomMetadataFixtures(state);
    seedStaticResource(
        state,
        "081000000000001",
        "sample_data_brokers",
        "[{\"Broker_Id__c\":1,\"Name\":\"Broker One\",\"Title__c\":\"Senior Broker\"}]");
    seedStaticResource(
        state,
        "081000000000002",
        "sample_data_properties",
        "[{\"Name\":\"Property One\",\"Address__c\":\"1 Main St\",\"City__c\":\"Cambridge\",\"State__c\":\"MA\",\"Price__c\":500000,\"Beds__c\":3,\"Baths__c\":2}]");
    seedStaticResource(
        state,
        "081000000000003",
        "sample_data_contacts",
        "[{\"FirstName\":\"Alice\",\"LastName\":\"Example\",\"Email\":\"alice@example.com\"}]");
    seedStaticResource(state, "081000000000004", "helloworld", Blob.valueOf("hello world"));
    seedStaticResource(state, "081000000000005", "helloaudio", Blob.valueOf("hello audio"));
    seedStaticResource(state, "081000000000006", "logo", Blob.valueOf("logo image"));
    seedAppMenuItem(state, "0MM000000000001", "Apex_Recipes", "02u000000000001");
    seedAppMenuItem(state, "0MM000000000002", "Sales", "02u000000000002");
    seedApexClass(
        state,
        "01p000000000001",
        "ApexClassUtilities",
        "/**\n * @group Shared Code\n * @see RecipeTreeViewController\n * @see FormattedRecipeDisplayController\n */\npublic class ApexClassUtilities {}",
        62.0);
    seedApexClass(
        state,
        "01p000000000002",
        "DynamicSOQLRecipes_Tests",
        "/**\n * @group Data Recipes\n */\npublic class DynamicSOQLRecipes_Tests {}",
        62.0);
    seedApexClass(
        state,
        "01p000000000003",
        "FormattedRecipeDisplayController",
        "/**\n * @group Shared Code\n */\npublic class FormattedRecipeDisplayController {}",
        62.0);
    seedApexClass(
        state,
        "01p000000000004",
        "FormattedRecipeDisplayController_Tests",
        "/**\n * @group Tests\n */\npublic class FormattedRecipeDisplayController_Tests {}",
        62.0);
    seedApexClass(
        state,
        "01p000000000005",
        "ApiServiceRecipes",
        "/**\n * @group Integration Recipes\n * @see RestClient\n * @see ApiServiceRecipesDataModel\n */\npublic class ApiServiceRecipes {}",
        62.0);
    seedApexClass(
        state,
        "01p000000000006",
        "DMLRecipes_Tests",
        "/**\n * @group Tests\n */\npublic class DMLRecipes_Tests {}",
        62.0);
    seedApexClass(
        state,
        "01p000000000007",
        "RecipeTreeViewController",
        "/**\n * @group Shared Code\n */\npublic class RecipeTreeViewController {}",
        62.0);
    seedApexClass(
        state,
        "01p000000000008",
        "SOQLRecipes",
        "/**\n * @group Data Recipes\n */\npublic class SOQLRecipes {}",
        62.0);
    return state;
  }

  /** Seed the current user record directly into the store (no triggers, no DML overhead). */
  static void seedCurrentUser() {
    State state = STATE.get();
    if (state == null) return;
    ApexSObject user = UserContext.currentUser();
    if (user == null) return;
    ApexSObject copy = user.copy();
    if (copy.getAs("Name") == null) copy.set("Name", UserInfo.getName());
    if (copy.getAs("Username") == null) copy.set("Username", UserInfo.getUsername());
    if (copy.getAs("Email") == null) copy.set("Email", UserInfo.getEmail());
    String profileId = UserInfo.getProfileId();
    if (copy.getAs("ProfileId") == null && profileId != null) copy.set("ProfileId", profileId);
    String id = copy.id();
    if (id == null || id.isBlank()) {
      id = UserContext.currentUserId();
      copy.withId(id);
    }
    state.active.computeIfAbsent("User", ignored -> new LinkedHashMap<>()).put(id, copy);
  }

  private static void seedProfile(
      State state,
      String id,
      String name,
      String userType,
      Boolean permissionsPrivacyDataAccess,
      Boolean permissionsSubmitMacrosAllowed,
      Boolean permissionsMassInlineEdit) {
    if (state == null || id == null || id.isBlank() || name == null || name.isBlank() || userType == null) {
      return;
    }
    ApexSObject profile =
        ApexSObject.of("Profile")
            .withId(id)
            .set("Name", name)
            .set("UserType", userType)
            .set("PermissionsPrivacyDataAccess", permissionsPrivacyDataAccess)
            .set("PermissionsSubmitMacrosAllowed", permissionsSubmitMacrosAllowed)
            .set("PermissionsMassInlineEdit", permissionsMassInlineEdit);
    state.active.computeIfAbsent("Profile", ignored -> new LinkedHashMap<>()).put(id, profile);
  }

  private static void seedPermissionSet(State state, String id, String name) {
    if (state == null || id == null || id.isBlank() || name == null || name.isBlank()) {
      return;
    }
    ApexSObject permissionSet = ApexSObject.of("PermissionSet").withId(id).set("Name", name);
    state.active.computeIfAbsent("PermissionSet", ignored -> new LinkedHashMap<>()).put(id, permissionSet);
  }

  private static void seedPermissionSetGroup(
      State state, String id, String developerName, String status) {
    if (state == null
        || id == null
        || id.isBlank()
        || developerName == null
        || developerName.isBlank()) {
      return;
    }
    ApexSObject group =
        ApexSObject.of("PermissionSetGroup")
            .withId(id)
            .set("DeveloperName", developerName)
            .set("Status", status == null || status.isBlank() ? "Updated" : status);
    state.active.computeIfAbsent("PermissionSetGroup", ignored -> new LinkedHashMap<>()).put(id, group);
  }

  private static void seedObjectPermission(
      State state,
      String id,
      String parentId,
      String objectType,
      Boolean read,
      Boolean create,
      Boolean edit,
      Boolean delete) {
    if (state == null
        || id == null
        || id.isBlank()
        || parentId == null
        || parentId.isBlank()
        || objectType == null
        || objectType.isBlank()) {
      return;
    }
    ApexSObject row =
        ApexSObject.of("ObjectPermissions")
            .withId(id)
            .set("ParentId", parentId)
            .set("SobjectType", objectType)
            .set("PermissionsRead", read)
            .set("PermissionsCreate", create)
            .set("PermissionsEdit", edit)
            .set("PermissionsDelete", delete);
    state.active.computeIfAbsent("ObjectPermissions", ignored -> new LinkedHashMap<>()).put(id, row);
  }

  private static void seedFieldPermission(
      State state,
      String id,
      String parentId,
      String fieldApiName,
      Boolean read,
      Boolean edit) {
    if (state == null
        || id == null
        || id.isBlank()
        || parentId == null
        || parentId.isBlank()
        || fieldApiName == null
        || fieldApiName.isBlank()) {
      return;
    }
    String objectType = fieldApiName;
    int dot = fieldApiName.indexOf('.');
    if (dot > 0) {
      objectType = fieldApiName.substring(0, dot);
    }
    ApexSObject row =
        ApexSObject.of("FieldPermissions")
            .withId(id)
            .set("ParentId", parentId)
            .set("SobjectType", objectType)
            .set("Field", fieldApiName)
            .set("PermissionsRead", read)
            .set("PermissionsEdit", edit);
    state.active.computeIfAbsent("FieldPermissions", ignored -> new LinkedHashMap<>()).put(id, row);
  }

  private static void seedPlatformCachePartition(
      State state, String id, String developerName, String namespacePrefix) {
    if (state == null
        || id == null
        || id.isBlank()
        || developerName == null
        || developerName.isBlank()) {
      return;
    }
    ApexSObject partition =
        ApexSObject.of("PlatformCachePartition")
            .withId(id)
            .set("DeveloperName", developerName)
            .set("NamespacePrefix", namespacePrefix == null ? "" : namespacePrefix);
    state.active
        .computeIfAbsent("PlatformCachePartition", ignored -> new LinkedHashMap<>())
        .put(id, partition);
  }

  private static void seedOrganization(State state, String id, String name) {
    if (state == null || id == null || id.isBlank()) {
      return;
    }
    ApexSObject organization =
        ApexSObject.of("Organization")
            .withId(id)
            .set("Name", name == null || name.isBlank() ? "Organization" : name)
            .set("IsSandbox", Boolean.FALSE)
            .set("InstanceName", "APEXGOV")
            .set("OrganizationType", "Developer Edition")
            .set("IsReadOnly", Boolean.FALSE)
            .set("FiscalYearStartMonth", Integer.valueOf(1))
            .set("LanguageLocaleKey", "en_US")
            .set("TimeZoneSidKey", "America/Los_Angeles")
            .set("NamespacePrefix", "");
    state.active.computeIfAbsent("Organization", ignored -> new LinkedHashMap<>()).put(id, organization);
  }

  private static void seedStandardPricebook(State state, String id) {
    if (state == null || id == null || id.isBlank()) {
      return;
    }
    ApexSObject pricebook =
        ApexSObject.of("Pricebook2")
            .withId(id)
            .set("Name", "Standard Price Book")
            .set("IsActive", Boolean.TRUE)
            .set("IsStandard", Boolean.TRUE);
    state.active.computeIfAbsent("Pricebook2", ignored -> new LinkedHashMap<>()).put(id, pricebook);
  }

  private static void seedCustomMetadataFixtures(State state) {
    if (state == null) {
      return;
    }

    ApexSObject objectDefinition =
        ApexSObject.of("EntityDefinition")
            .withId("01I000000000001")
            .set("QualifiedApiName", "Contact");
    ApexSObject fieldDefinition =
        ApexSObject.of("FieldDefinition")
            .withId("01J000000000001")
            .set("QualifiedApiName", "AttendanceStatus__c");
    state.active.computeIfAbsent("EntityDefinition", ignored -> new LinkedHashMap<>())
        .put(objectDefinition.id(), objectDefinition);
    state.active.computeIfAbsent("FieldDefinition", ignored -> new LinkedHashMap<>())
        .put(fieldDefinition.id(), fieldDefinition);

    ApexSObject bucketedPicklist =
        ApexSObject.of("Bucketed_Picklist__mdt")
            .withId("mBP000000000001")
            .set("DeveloperName", "Attendance")
            .set("Object__c", objectDefinition.id())
            .set("Field__c", fieldDefinition.id())
            .set("Object__r", objectDefinition.copy())
            .set("Field__r", fieldDefinition.copy());
    state.active.computeIfAbsent("Bucketed_Picklist__mdt", ignored -> new LinkedHashMap<>())
        .put(bucketedPicklist.id(), bucketedPicklist);

    ApexSObject picklistBucket =
        ApexSObject.of("Picklist_Bucket__mdt")
            .withId("mPB000000000001")
            .set("DeveloperName", "Attended")
            .set("Bucketed_Picklist__c", bucketedPicklist.id());
    state.active.computeIfAbsent("Picklist_Bucket__mdt", ignored -> new LinkedHashMap<>())
        .put(picklistBucket.id(), picklistBucket);

    ApexSObject picklistValue =
        ApexSObject.of("Bucketed_Picklist_value__mdt")
            .withId("mPV000000000001")
            .set("DeveloperName", "Asleep")
            .set("Label", "Asleep")
            .set("Picklist_Bucket__c", picklistBucket.id());
    state.active.computeIfAbsent("Bucketed_Picklist_value__mdt", ignored -> new LinkedHashMap<>())
        .put(picklistValue.id(), picklistValue);

    ApexSObject picklistValueRelation =
        ApexSObject.of("Bucketed_Picklist_values__c")
            .withId("a0V000000000001")
            .set("DeveloperName", "Asleep")
            .set("Label", "Asleep")
            .set("Picklist_Bucket__mdtId", picklistBucket.id());
    state.active.computeIfAbsent("Bucketed_Picklist_values__c", ignored -> new LinkedHashMap<>())
        .put(picklistValueRelation.id(), picklistValueRelation);
  }

  private static void seedStaticResource(State state, String id, String name, Object body) {
    if (state == null
        || id == null
        || id.isBlank()
        || name == null
        || name.isBlank()
        || body == null) {
      return;
    }
    ApexSObject resource =
        ApexSObject.of("StaticResource")
            .withId(id)
            .set("Name", name)
            .set("Body", body);
    state.active.computeIfAbsent("StaticResource", ignored -> new LinkedHashMap<>()).put(id, resource);
  }

  private static void seedAppMenuItem(
      State state, String id, String name, String applicationId) {
    if (state == null
        || id == null
        || id.isBlank()
        || name == null
        || name.isBlank()
        || applicationId == null
        || applicationId.isBlank()) {
      return;
    }
    ApexSObject item =
        ApexSObject.of("AppMenuItem")
            .withId(id)
            .set("Name", name)
            .set("ApplicationId", applicationId);
    state.active.computeIfAbsent("AppMenuItem", ignored -> new LinkedHashMap<>()).put(id, item);
  }

  private static void seedApexClass(
      State state, String id, String name, String body, Double apiVersion) {
    if (state == null
        || id == null
        || id.isBlank()
        || name == null
        || name.isBlank()
        || body == null) {
      return;
    }
    ApexSObject klass =
        ApexSObject.of("ApexClass")
            .withId(id)
            .set("Name", name)
            .set("Body", body)
            .set("ApiVersion", apiVersion == null ? 62.0 : apiVersion)
            .set("LengthWithoutComments", body.length());
    state.active.computeIfAbsent("ApexClass", ignored -> new LinkedHashMap<>()).put(id, klass);
  }

  /**
   * Resolve an SObject type name from an ID by scanning all active stores.
   */
  static String resolveTypeFromId(String id) {
    if (id == null || id.isBlank()) {
      return null;
    }
    State state = STATE.get();
    for (Map.Entry<String, Map<String, ApexSObject>> entry : state.active.entrySet()) {
      if (entry.getValue().containsKey(id)) {
        return entry.getKey();
      }
    }
    return null;
  }

  /**
   * Check if the current user has an ObjectPermission granting a specific CRUD operation
   * via an assigned PermissionSet.
   */
  static boolean hasObjectPermission(String objectType, String permissionField) {
    if (objectType == null || objectType.isBlank() || permissionField == null || permissionField.isBlank()) {
      return false;
    }
    String userId = UserContext.currentUserId();
    State state = STATE.get();
    Set<String> permissionSetIds = resolveAssignedPermissionSetIds(state, userId);
    if (permissionSetIds.isEmpty()) return false;
    Map<String, ApexSObject> opStore = state.active.get("ObjectPermissions");
    if (opStore == null || opStore.isEmpty()) return false;
    for (ApexSObject op : opStore.values()) {
      String parentId = normalizeId(op.getAs("ParentId"));
      if (parentId == null || !containsIgnoreCase(permissionSetIds, parentId)) continue;
      String opType = op.getAs("SobjectType");
      if (opType == null || !opType.equalsIgnoreCase(objectType)) continue;
      Object value = op.get(permissionField);
      if (value instanceof Boolean b && b) return true;
      if (value instanceof String s && "true".equalsIgnoreCase(s)) return true;
    }
    return false;
  }

  /**
   * Check if the current user has a FieldPermission granting a specific access level
   * for a field on a given object via an assigned PermissionSet.
   *
   * @param objectType the SObject type (e.g. "Campaign")
   * @param fieldName the field API name (e.g. "ActualCost")
   * @param permissionField "PermissionsRead" or "PermissionsEdit"
   */
  static boolean hasFieldPermission(String objectType, String fieldName, String permissionField) {
    if (objectType == null || fieldName == null || permissionField == null) {
      return false;
    }
    String userId = UserContext.currentUserId();
    State state = STATE.get();
    Set<String> permissionSetIds = resolveAssignedPermissionSetIds(state, userId);
    if (permissionSetIds.isEmpty()) return false;
    Map<String, ApexSObject> fpStore = state.active.get("FieldPermissions");
    if (fpStore == null || fpStore.isEmpty()) return false;
    for (ApexSObject fp : fpStore.values()) {
      String parentId = normalizeId(fp.getAs("ParentId"));
      if (parentId == null || !containsIgnoreCase(permissionSetIds, parentId)) continue;
      String fpField = fp.getAs("Field");
      // FieldPermissions.Field stores "ObjectType.FieldName"
      String expected = objectType + "." + fieldName;
      if (fpField == null) continue;
      if (!fpField.equalsIgnoreCase(expected) && !fpField.equalsIgnoreCase(fieldName)) continue;
      Object value = fp.get(permissionField);
      if (value instanceof Boolean b && b) return true;
      if (value instanceof String s && "true".equalsIgnoreCase(s)) return true;
    }
    return false;
  }

  private static Set<String> resolveAssignedPermissionSetIds(State state, String userId) {
    Set<String> ids = new LinkedHashSet<>();
    if (state == null) {
      return ids;
    }
    String normalizedUserId = normalizeId(userId);
    if (normalizedUserId == null) {
      return ids;
    }
    Map<String, ApexSObject> psaStore = state.active.get("PermissionSetAssignment");
    if (psaStore == null || psaStore.isEmpty()) {
      return ids;
    }
    Map<String, ApexSObject> psgcStore = state.active.get("PermissionSetGroupComponent");
    for (ApexSObject psa : psaStore.values()) {
      String assigneeId = normalizeId(psa.getAs("AssigneeId"));
      if (assigneeId == null || !assigneeId.equalsIgnoreCase(normalizedUserId)) continue;

      String permissionSetId = normalizeId(psa.getAs("PermissionSetId"));
      if (permissionSetId != null) {
        ids.add(permissionSetId);
      }

      String permissionSetGroupId = normalizeId(psa.getAs("PermissionSetGroupId"));
      if (permissionSetGroupId == null || psgcStore == null || psgcStore.isEmpty()) {
        continue;
      }
      for (ApexSObject component : psgcStore.values()) {
        String componentGroupId = normalizeId(component.getAs("PermissionSetGroupId"));
        if (componentGroupId == null || !componentGroupId.equalsIgnoreCase(permissionSetGroupId)) {
          continue;
        }
        String componentPermissionSetId = normalizeId(component.getAs("PermissionSetId"));
        if (componentPermissionSetId != null) {
          ids.add(componentPermissionSetId);
        }
      }
    }
    return ids;
  }

  private static boolean containsIgnoreCase(Set<String> values, String target) {
    if (values == null || values.isEmpty() || target == null) {
      return false;
    }
    for (String value : values) {
      if (value != null && value.equalsIgnoreCase(target)) {
        return true;
      }
    }
    return false;
  }

  static void setSoqlNullOrderDefault(Database.NullOrderDefault mode) {
    CONFIG.get().nullOrderDefault = normalizeNullOrderDefault(mode);
  }

  static Database.NullOrderDefault getSoqlNullOrderDefault() {
    return normalizeNullOrderDefault(CONFIG.get().nullOrderDefault);
  }

  static Database.SaveResult[] insert(Collection<ApexSObject> records, boolean allOrNone) {
    return apply(records, allOrNone, DmlVerb.INSERT, ApexStore::insertOne);
  }

  static Database.SaveResult[] update(Collection<ApexSObject> records, boolean allOrNone) {
    return apply(records, allOrNone, DmlVerb.UPDATE, ApexStore::updateOne);
  }

  static Database.SaveResult[] upsert(Collection<ApexSObject> records, boolean allOrNone) {
    return upsert(records, allOrNone, null);
  }

  static Database.SaveResult[] upsert(
      Collection<ApexSObject> records, boolean allOrNone, String externalIdFieldName) {
    List<ApexSObject> normalized = normalize(records);
    if (normalized.isEmpty()) {
      return new Database.SaveResult[0];
    }

    State state = STATE.get();
    Limits.addDml(1);
    String externalField = normalizeExternalIdFieldName(externalIdFieldName);
    if (allOrNone) {
      return applyUpsertAllOrNone(state, normalized, externalField);
    }
    return applyUpsertPartial(state, normalized, externalField);
  }

  static Database.SaveResult[] delete(Collection<ApexSObject> records, boolean allOrNone) {
    return apply(records, allOrNone, DmlVerb.DELETE, ApexStore::deleteOne);
  }

  static Database.SaveResult[] undelete(Collection<ApexSObject> records, boolean allOrNone) {
    return apply(records, allOrNone, DmlVerb.UNDELETE, ApexStore::undeleteOne);
  }

  static Database.MergeResult merge(
      ApexSObject masterRecord, Collection<ApexSObject> duplicateRecords, boolean allOrNone) {
    State state = STATE.get();
    List<ApexSObject> normalizedDuplicates = normalize(duplicateRecords);
    Limits.addDml(1);

    StateSnapshot original = snapshotOf(state);
    try {
      return mergeOne(state, masterRecord, normalizedDuplicates);
    } catch (RuntimeException error) {
      restore(state, original);
      String messagePrefix = allOrNone ? "allOrNone rollback" : null;
      return mergeFailure(
          masterRecord == null ? null : masterRecord.id(), classifyFailure(error), messagePrefix);
    }
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
    STATE.get().semiJoinCache.clear();
    boolean enforceReadAccess =
        soql != null
            && (containsIgnoreCase(soql, "WITH USER_MODE")
                || containsIgnoreCase(soql, "WITH SECURITY_ENFORCED"));
    // Strip WITH clauses before parsing — they are access-control modifiers
    // that don't affect query semantics in the emulation environment.
    String cleanedSoql = stripWithClauses(soql);
    QuerySpec spec = parseQuerySpec(cleanedSoql);
    if (enforceReadAccess) {
      checkReadAccessForQuery(spec);
    }
    List<ApexSObject> all = scan(spec, false);
    // Aggregate queries already return AggregateResult instances — return as-is
    if (isAggregateQuery(spec)) {
      Limits.addSoql(1);
      Limits.addHeapBytes(all.size() * 256L);
      return all;
    }
    Set<String> selectedFields = collectSelectedFields(spec);
    List<ApexSObject> out = new ArrayList<>(all.size());
    for (ApexSObject row : all) {
      ApexSObject projected = row.copy();
      if (selectedFields != null) {
        projected.retainFields(selectedFields);
        projected.markQueriedFields(selectedFields);
      }
      attachParentRecordFields(spec, row, projected);
      attachChildSubqueryRows(spec, row, projected);
      out.add(projected);
    }
    Limits.addSoql(1);
    Limits.addHeapBytes(out.size() * 256L);
    return out;
  }

  /** Embed resolved parent records for relationship field paths in SELECT (e.g. Account.Name). */
  private static void attachParentRecordFields(QuerySpec spec, ApexSObject sourceRow, ApexSObject projectedRow) {
    if (spec == null || spec.selectSpec == null || spec.selectSpec.items == null) {
      return;
    }
    Set<String> attachedRelationships = new HashSet<>();
    for (SelectItem item : spec.selectSpec.items) {
      if (item.kind() != SelectItemKind.FIELD || item.field() == null) {
        continue;
      }
      String field = item.field();
      DatePartField datePartField = parseDatePartFieldExpression(field);
      if (datePartField != null) {
        field = datePartField.fieldPath();
      }
      if (!field.contains(".")) {
        continue;
      }
      String relationshipSegment = field.substring(0, field.indexOf('.'));
      String relLower = relationshipSegment.toLowerCase();
      if (attachedRelationships.contains(relLower)) {
        continue;
      }
      attachedRelationships.add(relLower);
      ApexSObject parentRecord = resolveRelationshipHop(sourceRow, relationshipSegment);
      if (parentRecord != null) {
        projectedRow.set(relationshipSegment, parentRecord.copy());
      }
    }
  }

  /** Collect lowercase field names from the SELECT clause. Returns null if all fields should be kept (e.g. aggregate-only query). */
  private static Set<String> collectSelectedFields(QuerySpec spec) {
    if (spec == null || spec.selectSpec == null || spec.selectSpec.items == null) {
      return null;
    }
    if (spec.selectSpec.hasAggregate) {
      return null; // aggregate queries return AggregateResult, not SObject field projection
    }
    Set<String> fields = new HashSet<>();
    fields.add("id"); // Id is always included
    for (SelectItem item : spec.selectSpec.items) {
      if (item.kind() == SelectItemKind.FIELDS_SELECTOR) {
        return null;
      }
      if (item.kind() == SelectItemKind.FIELD && item.field() != null) {
        String f = item.field();
        DatePartField datePartField = parseDatePartFieldExpression(f);
        if (datePartField != null) {
          f = datePartField.fieldPath();
        }
        f = f.toLowerCase();
        fields.add(f);
        if (f.contains(".")) {
          String relSegment = f.substring(0, f.indexOf('.')).toLowerCase();
          fields.add(relSegment);
          // Also keep the foreign key field (e.g., "accountid" for "account")
          fields.add(relSegment.replaceAll("__r$", "__c") + (relSegment.endsWith("__r") ? "" : "id"));
        }
      } else if (item.kind() == SelectItemKind.CHILD_SUBQUERY && item.childSubquery() != null) {
        String rel = item.outputName();
        if (rel != null) {
          fields.add(rel.toLowerCase());
        }
      }
    }
    return fields;
  }

  static int countQuery(String soql) {
    STATE.get().semiJoinCache.clear();
    QuerySpec spec = parseQuerySpec(soql);
    int count = scan(spec, true).size();
    Limits.addSoql(1);
    return count;
  }

  static List<ApexSObject> queryWithBinds(String soql, Map<String, Object> bindVariables) {
    return query(applyBindVariables(soql, bindVariables));
  }

  static int countQueryWithBinds(String soql, Map<String, Object> bindVariables) {
    return countQuery(applyBindVariables(soql, bindVariables));
  }

  static List<List<ApexSObject>> search(String sosl) {
    SoslSpec spec = parseSoslSpec(sosl);
    State state = STATE.get();
    List<List<ApexSObject>> out = new ArrayList<>(spec.returningTypes.size());

    List<String> fixedSearchResults = Test.getFixedSearchResults();
    if (fixedSearchResults != null && !fixedSearchResults.isEmpty()) {
      for (String typeName : spec.returningTypes) {
        List<ApexSObject> groupRows = new ArrayList<>();
        for (String rowId : fixedSearchResults) {
          if (rowId == null || rowId.isBlank()) {
            continue;
          }
          ApexSObject row = findActiveRowByIdAndType(rowId, typeName);
          if (row != null) {
            groupRows.add(row.copy());
          }
        }
        out.add(groupRows);
      }
      Limits.addSoql(1);
      Limits.addHeapBytes((long) fixedSearchResults.size() * 256L);
      return out;
    }

    for (String typeName : spec.returningTypes) {
      List<ApexSObject> groupRows = new ArrayList<>();
      Map<String, ApexSObject> bucket = findBucketByType(state.active, typeName);
      if (bucket != null && !bucket.isEmpty()) {
        for (ApexSObject row : bucket.values()) {
          if (!matchesSoslTerm(row, spec.term, spec.nameFieldsOnly)) {
            continue;
          }
          groupRows.add(row.copy());
        }
      }
      out.add(groupRows);
    }

    Limits.addSoql(1);
    Limits.addHeapBytes((long) out.stream().mapToInt(List::size).sum() * 256L);
    return out;
  }

  static List<List<ApexSObject>> searchWithBinds(String sosl, Map<String, Object> bindVariables) {
    return search(applyBindVariables(sosl, bindVariables));
  }

  private static Database.SaveResult[] apply(
      Collection<ApexSObject> records, boolean allOrNone, DmlVerb verb, DmlOperation operation) {
    List<ApexSObject> normalized = normalize(records);
    if (normalized.isEmpty()) {
      return new Database.SaveResult[0];
    }

    State state = STATE.get();
    Limits.addDml(1);

    if (allOrNone) {
      return applyAllOrNoneWithTrigger(state, normalized, verb, operation);
    }
    return applyPartialWithTrigger(state, normalized, verb, operation);
  }

  private static Database.SaveResult[] applyUpsertAllOrNone(
      State state, List<ApexSObject> normalized, String externalIdFieldName) {
    StateSnapshot original = snapshotOf(state);
    try {
      clearRecordErrors(normalized);
      List<UpsertPlanRow> plan = planUpsertRows(state, normalized, externalIdFieldName);

      List<ApexSObject> insertNew = upsertPlanNewRows(plan, UpsertPath.INSERT);
      List<ApexSObject> updateNew = upsertPlanNewRows(plan, UpsertPath.UPDATE);
      List<ApexSObject> updateOld = upsertPlanOldRows(plan);

      dispatchBefore(state, DmlVerb.INSERT, insertNew, null);
      dispatchBefore(state, DmlVerb.UPDATE, updateNew, updateOld);
      throwIfRecordErrors(insertNew);
      throwIfRecordErrors(updateNew);

      Database.SaveResult[] out = new Database.SaveResult[normalized.size()];
      for (UpsertPlanRow row : plan) {
        String id =
            row.path == UpsertPath.UPDATE
                ? updateOne(state, row.record)
                : insertOne(state, row.record);
        out[row.index] = success(id, row.path == UpsertPath.INSERT);
      }

      List<ApexSObject> insertedAfter = snapshotActiveRows(state, insertNew, "upsert");
      List<ApexSObject> updatedAfter = snapshotActiveRows(state, updateNew, "upsert");

      dispatchAfter(DmlVerb.INSERT, insertedAfter, null);
      dispatchAfter(DmlVerb.UPDATE, updatedAfter, updateOld);
      throwIfRecordErrors(insertedAfter);
      throwIfRecordErrors(updatedAfter);
      return out;
    } catch (RuntimeException error) {
      restore(state, original);
      return allOrNoneFailures(normalized, classifyFailure(error));
    }
  }

  private static Database.SaveResult[] applyUpsertPartial(
      State state, List<ApexSObject> normalized, String externalIdFieldName) {
    Database.SaveResult[] out = new Database.SaveResult[normalized.size()];
    for (int i = 0; i < normalized.size(); i += 1) {
      ApexSObject record = normalized.get(i);
      try {
        clearRecordErrors(List.of(record));
        UpsertPath path = resolveUpsertPath(state, record, externalIdFieldName);
        if (path == UpsertPath.UPDATE) {
          List<ApexSObject> singleRecord = List.of(record);
          List<ApexSObject> oldRows = List.of(snapshotActiveRow(state, record, "upsert"));
          dispatchBefore(state, DmlVerb.UPDATE, singleRecord, oldRows);
          throwIfRecordErrors(singleRecord);
          String id = updateOne(state, record);
          List<ApexSObject> newRows = snapshotActiveRows(state, singleRecord, "upsert");
          dispatchAfter(DmlVerb.UPDATE, newRows, oldRows);
          throwIfRecordErrors(newRows);
          out[i] = success(id, false);
        } else {
          List<ApexSObject> singleRecord = List.of(record);
          dispatchBefore(state, DmlVerb.INSERT, singleRecord, null);
          throwIfRecordErrors(singleRecord);
          String id = insertOne(state, record);
          List<ApexSObject> newRows = snapshotActiveRows(state, singleRecord, "upsert");
          dispatchAfter(DmlVerb.INSERT, newRows, null);
          throwIfRecordErrors(newRows);
          out[i] = success(id, true);
        }
      } catch (RuntimeException error) {
        out[i] = failure(record == null ? null : record.id(), classifyFailure(error), null);
      }
    }
    return out;
  }

  private static Database.SaveResult[] applyAllOrNoneWithTrigger(
      State state, List<ApexSObject> normalized, DmlVerb verb, DmlOperation operation) {
    StateSnapshot original = snapshotOf(state);
    try {
      clearRecordErrors(normalized);
      List<ApexSObject> beforeOld = beforeOldRecords(state, verb, normalized);
      dispatchBefore(state, verb, normalized, beforeOld);
      throwIfRecordErrors(normalized);

      Database.SaveResult[] successes = new Database.SaveResult[normalized.size()];
      for (int i = 0; i < normalized.size(); i += 1) {
        ApexSObject record = normalized.get(i);
        String id = operation.apply(state, record);
        successes[i] = success(id);
      }

      List<ApexSObject> afterNew = afterNewRecords(state, verb, normalized);
      dispatchAfter(verb, afterNew, beforeOld);
      throwIfRecordErrors(afterNew);
      return successes;
    } catch (RuntimeException error) {
      restore(state, original);
      return allOrNoneFailures(normalized, classifyFailure(error));
    }
  }

  private static Database.SaveResult[] applyPartialWithTrigger(
      State state, List<ApexSObject> normalized, DmlVerb verb, DmlOperation operation) {
    Database.SaveResult[] out = new Database.SaveResult[normalized.size()];
    for (int i = 0; i < normalized.size(); i += 1) {
      ApexSObject record = normalized.get(i);
      List<ApexSObject> singleRecord = List.of(record);
      try {
        clearRecordErrors(singleRecord);
        List<ApexSObject> beforeOld = beforeOldRecords(state, verb, singleRecord);
        dispatchBefore(state, verb, singleRecord, beforeOld);
        throwIfRecordErrors(singleRecord);

        String id = operation.apply(state, record);
        List<ApexSObject> afterNew = afterNewRecords(state, verb, singleRecord);
        dispatchAfter(verb, afterNew, beforeOld);
        throwIfRecordErrors(afterNew);
        out[i] = success(id);
      } catch (RuntimeException error) {
        out[i] = failure(record == null ? null : record.id(), classifyFailure(error), null);
      }
    }
    return out;
  }

  private static void clearRecordErrors(List<ApexSObject> records) {
    if (records == null) {
      return;
    }
    for (ApexSObject record : records) {
      if (record != null) {
        record.clearErrors();
      }
    }
  }

  private static void throwIfRecordErrors(List<ApexSObject> records) {
    if (records == null) {
      return;
    }
    for (ApexSObject record : records) {
      if (record == null || !record.hasErrors()) {
        continue;
      }
      Database.Error[] errors = record.getErrors();
      if (errors == null || errors.length == 0 || errors[0] == null) {
        throw new DmlFailure("FIELD_CUSTOM_VALIDATION_EXCEPTION", "validation error", new String[0]);
      }
      Database.Error first = errors[0];
      throw new DmlFailure(first.getStatusCode(), first.getMessage(), first.getFields());
    }
  }

  private static Database.SaveResult[] allOrNoneFailures(
      List<ApexSObject> normalized, FailureInfo root) {
    Database.SaveResult[] failures = new Database.SaveResult[normalized.size()];
    for (int i = 0; i < normalized.size(); i += 1) {
      ApexSObject row = normalized.get(i);
      failures[i] = failure(row == null ? null : row.id(), root, "allOrNone rollback");
    }
    return failures;
  }

  private static String insertOne(State state, ApexSObject raw) {
    ApexSObject record = requireRecord(raw);
    resolveReferenceFields(state, record);
    applyDerivedSalesItemFields(state, record);
    validateForInsert(state, record);
    ApexSObject stored = record.copy();
    applyDerivedNameFields(stored);
    applyDerivedSalesItemFields(state, stored);
    stored.set("IsDeleted", Boolean.FALSE);

    String id = normalizeId(stored.id());
    if (id == null) {
      id = nextId(state, stored.type());
      stored.withId(id);
      record.withId(id);
    }

    if (hasIdCollision(state, stored.type(), id)) {
      throw new IllegalArgumentException("duplicate id for insert: " + stored.type() + "#" + id);
    }

    if (isType(stored.type(), "ContentVersion")) {
      ensureContentVersionDocumentLinkage(state, stored, record, id);
    }
    if (isType(stored.type(), "ContentDistribution")) {
      ensureContentDistributionFields(stored, record, id);
    }

    applySystemTimestampsOnInsert(stored, record);

    Map<String, ApexSObject> bucket = state.active.computeIfAbsent(stored.type(), ignored -> new LinkedHashMap<>());
    bucket.put(id, stored);
    syncRelatedRollups(state, null, stored);
    if (isType(stored.type(), "EmailMessage")) {
      ensureEmailMessageToRelations(state, stored, record, id);
    }
    return id;
  }

  private static String updateOne(State state, ApexSObject raw) {
    ApexSObject record = requireRecord(raw);
    resolveReferenceFields(state, record);
    applyDerivedSalesItemFields(state, record);
    validateForUpdate(state, record);
    String id = requireId(record, "update");

    Map<String, ApexSObject> bucket = state.active.get(record.type());
    if (bucket == null || !bucket.containsKey(id)) {
      throw new IllegalArgumentException("record not found for update: " + record.type() + "#" + id);
    }

    ApexSObject stored = bucket.get(id).copy();
    ApexSObject beforeUpdate = stored.copy();
    for (Map.Entry<String, Object> field : record.fields().entrySet()) {
      stored.set(field.getKey(), field.getValue());
    }
    applyDerivedNameFields(stored);
    applyDerivedSalesItemFields(state, stored);
    stored.set("IsDeleted", Boolean.FALSE);
    applySystemTimestampsOnUpdate(stored, record);
    bucket.put(id, stored);
    syncRelatedRollups(state, beforeUpdate, stored);
    return id;
  }

  private static String upsertOne(State state, ApexSObject raw) {
    ApexSObject record = requireRecord(raw);
    return resolveUpsertPath(state, record, null) == UpsertPath.UPDATE
        ? updateOne(state, record)
        : insertOne(state, record);
  }

  private static void applyDerivedNameFields(ApexSObject record) {
    if (record == null) {
      return;
    }
    if (isType(record.type(), "Contact") || isType(record.type(), "User") || isType(record.type(), "Lead")) {
      String first = trimToNull(safeGet(record, "FirstName"));
      String last = trimToNull(safeGet(record, "LastName"));
      if (first == null && last == null) {
        // fall through to generic Name synthesis for records without person-name parts
      } else {
        String fullName;
        if (first != null && last != null) {
          fullName = first + " " + last;
        } else if (first != null) {
          fullName = first;
        } else {
          fullName = last;
        }
        record.set("Name", fullName);
      }
    }

    if (isBlankValue(record.get("Name"))) {
      String type = record.type();
      if (type != null
          && (type.endsWith("__c")
              || type.endsWith("__mdt")
              || isType(type, "Organization")
              || isType(type, "ApexClass"))) {
        String suffix = trimToNull(record.id());
        if (suffix == null) {
          suffix = "record";
        }
        record.set("Name", type + " " + suffix);
      }
    }
  }

  private static void applyDerivedSalesItemFields(State state, ApexSObject record) {
    if (record == null || !isType(record.type(), "OpportunityLineItem")) {
      return;
    }

    Double quantity = toNumber(record.get("Quantity"));
    Double unitPrice = toNumber(record.get("UnitPrice"));
    Double totalPrice = toNumber(record.get("TotalPrice"));

    if (unitPrice == null) {
      if (quantity != null && Double.compare(quantity, 0.0d) != 0 && totalPrice != null) {
        unitPrice = totalPrice / quantity;
        record.set("UnitPrice", unitPrice);
      } else {
        Object pricebookEntryIdRaw = record.get("PricebookEntryId");
        if (pricebookEntryIdRaw instanceof String pricebookEntryId && !pricebookEntryId.isBlank()) {
          ApexSObject pricebookEntry = findActiveRowByIdAndType(pricebookEntryId, "PricebookEntry");
          Double entryUnitPrice = pricebookEntry == null ? null : toNumber(pricebookEntry.get("UnitPrice"));
          if (entryUnitPrice != null) {
            unitPrice = entryUnitPrice;
            record.set("UnitPrice", entryUnitPrice);
          }
        }
      }
    }

    if (record.get("ListPrice") == null) {
      Object pricebookEntryIdRaw = record.get("PricebookEntryId");
      if (pricebookEntryIdRaw instanceof String pricebookEntryId && !pricebookEntryId.isBlank()) {
        ApexSObject pricebookEntry = findActiveRowByIdAndType(pricebookEntryId, "PricebookEntry");
        Double entryUnitPrice = pricebookEntry == null ? null : toNumber(pricebookEntry.get("UnitPrice"));
        if (entryUnitPrice != null) {
          record.set("ListPrice", entryUnitPrice);
        }
      }
    }

    if (unitPrice != null && quantity != null) {
      record.set("TotalPrice", unitPrice * quantity);
    }
  }

  private static void syncRelatedRollups(State state, ApexSObject before, ApexSObject after) {
    if (state == null) {
      return;
    }
    if (!isType(before == null ? null : before.type(), "OpportunityLineItem")
        && !isType(after == null ? null : after.type(), "OpportunityLineItem")) {
      return;
    }

    Set<String> opportunityIds = new LinkedHashSet<>();
    addOpportunityRollupId(opportunityIds, before);
    addOpportunityRollupId(opportunityIds, after);
    for (String opportunityId : opportunityIds) {
      syncOpportunityAmountFromLineItems(state, opportunityId);
    }
  }

  private static void addOpportunityRollupId(Set<String> opportunityIds, ApexSObject lineItem) {
    if (opportunityIds == null || lineItem == null) {
      return;
    }
    Object rawOpportunityId = lineItem.get("OpportunityId");
    if (rawOpportunityId instanceof String opportunityId && !opportunityId.isBlank()) {
      opportunityIds.add(opportunityId);
    }
  }

  private static void syncOpportunityAmountFromLineItems(State state, String opportunityId) {
    if (state == null || opportunityId == null || opportunityId.isBlank()) {
      return;
    }
    ApexSObject opportunity = findActiveRowByIdAndType(opportunityId, "Opportunity");
    if (opportunity == null) {
      return;
    }

    Map<String, ApexSObject> lineItems = findBucketByType(state.active, "OpportunityLineItem");
    if (lineItems == null || lineItems.isEmpty()) {
      opportunity.set("Amount", null);
      return;
    }

    double totalAmount = 0.0d;
    boolean hasLineItems = false;
    for (ApexSObject lineItem : lineItems.values()) {
      if (lineItem == null) {
        continue;
      }
      Object rawOpportunityId = lineItem.get("OpportunityId");
      if (!(rawOpportunityId instanceof String lineOpportunityId)
          || !lineOpportunityId.equalsIgnoreCase(opportunityId)) {
        continue;
      }
      hasLineItems = true;
      Double lineTotal = toNumber(lineItem.get("TotalPrice"));
      if (lineTotal == null) {
        Double lineUnitPrice = toNumber(lineItem.get("UnitPrice"));
        Double lineQuantity = toNumber(lineItem.get("Quantity"));
        if (lineUnitPrice != null && lineQuantity != null) {
          lineTotal = lineUnitPrice * lineQuantity;
        }
      }
      if (lineTotal != null) {
        totalAmount += lineTotal;
      }
    }

    opportunity.set("Amount", hasLineItems ? totalAmount : null);
  }

  private static Object safeGet(ApexSObject record, String fieldName) {
    if (record == null || fieldName == null || fieldName.isBlank()) {
      return null;
    }
    try {
      return record.get(fieldName);
    } catch (SObjectException ignored) {
      return null;
    }
  }

  private static String trimToNull(Object value) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value).trim();
    return text.isEmpty() ? null : text;
  }

  private static void resolveReferenceFields(State state, ApexSObject record) {
    if (state == null || record == null || record.type() == null) {
      return;
    }
    if (isType(record.type(), "Contact")) {
      boolean needsAccountResolution = !record.hasField("AccountId");
      if (record.hasField("AccountId")) {
        needsAccountResolution = isBlankValue(record.get("AccountId"));
      }
      if (needsAccountResolution) {
        Object accountRefRaw = record.hasField("Account") ? record.get("Account") : null;
        if (accountRefRaw instanceof ApexSObject accountRef) {
          String resolvedAccountId = normalizeId(accountRef.id());
          if (resolvedAccountId == null) {
            Object external = accountRef.get("ExternalSalesforceId__c");
            if (!isBlankValue(external)) {
              resolvedAccountId =
                  findRecordIdByFieldValue(state, "Account", "ExternalSalesforceId__c", external);
            }
          }
          if (resolvedAccountId != null) {
            record.set("AccountId", resolvedAccountId);
          }
        }
      }
      return;
    }
  }

  private static String findRecordIdByFieldValue(
      State state, String typeName, String fieldName, Object expected) {
    if (state == null || typeName == null || fieldName == null || expected == null) {
      return null;
    }
    Map<String, ApexSObject> bucket = findBucketByType(state.active, typeName);
    if (bucket == null || bucket.isEmpty()) {
      return null;
    }
    for (ApexSObject row : bucket.values()) {
      if (row == null) {
        continue;
      }
      Object actual = row.get(fieldName);
      if (valuesEqualForField(actual, expected)) {
        return normalizeId(row.id());
      }
    }
    return null;
  }

  private static boolean valuesEqualForField(Object actual, Object expected) {
    if (actual == expected) {
      return true;
    }
    if (actual == null || expected == null) {
      return false;
    }
    if (compareEquality(actual, expected)) {
      return true;
    }

    if (actual instanceof ApexSObject actualRecord) {
      String actualId = normalizeId(actualRecord.id());
      if (actualId != null && compareEquality(actualId, expected)) {
        return true;
      }
    }
    if (expected instanceof ApexSObject expectedRecord) {
      String expectedId = normalizeId(expectedRecord.id());
      if (expectedId != null && compareEquality(actual, expectedId)) {
        return true;
      }
    }

    if (actual instanceof String actualText && expected instanceof String expectedText) {
      return actualText.trim().equalsIgnoreCase(expectedText.trim());
    }
    return false;
  }

  private static UpsertPath resolveUpsertPath(
      State state, ApexSObject raw, String externalIdFieldName) {
    ApexSObject record = requireRecord(raw);
    String id = normalizeId(record.id());
    if (id == null) {
      if (externalIdFieldName == null || externalIdFieldName.isBlank()) {
        return UpsertPath.INSERT;
      }
      return resolveUpsertPathByExternalId(state, record, externalIdFieldName);
    }
    Map<String, ApexSObject> bucket = state.active.get(record.type());
    if (bucket != null && bucket.containsKey(id)) {
      return UpsertPath.UPDATE;
    }
    // Record has an ID but it doesn't exist — in Salesforce this is
    // INVALID_CROSS_REFERENCE_KEY (upsert with non-existent ID).
    throw new DmlFailure(
        "INVALID_CROSS_REFERENCE_KEY",
        "invalid cross reference id: " + id,
        new String[] {"Id"});
  }

  private static String normalizeExternalIdFieldName(String fieldName) {
    if (fieldName == null || fieldName.isBlank()) {
      return null;
    }
    return fieldName.trim();
  }

  private static UpsertPath resolveUpsertPathByExternalId(
      State state, ApexSObject record, String externalIdFieldName) {
    String fieldName = normalizeExternalIdFieldName(externalIdFieldName);
    if (fieldName == null) {
      return UpsertPath.INSERT;
    }

    Schema.ObjectDefinition definition = Schema.find(record.type());
    if (definition == null) {
      // No schema registered — fall back to insert (cannot resolve external id)
      return UpsertPath.INSERT;
    }
    Schema.FieldDefinition field = definition.field(fieldName);
    if (field == null) {
      // Field not in partial schema — fall back to insert
      return UpsertPath.INSERT;
    }
    if (!field.externalId && !field.unique) {
      throw new DmlFailure(
          "INVALID_FIELD_FOR_INSERT_UPDATE",
          "field is not marked as externalId/unique: " + fieldName,
          new String[] {field.name});
    }

    Object externalValue = record.get(field.name);
    if (externalValue == null) {
      return UpsertPath.INSERT;
    }

    List<ApexSObject> matches =
        findRowsByFieldValue(state, record.type(), field.name, externalValue, null);
    if (matches.isEmpty()) {
      return UpsertPath.INSERT;
    }
    if (matches.size() > 1) {
      throw new DmlFailure(
          "DUPLICATE_VALUE",
          "duplicate external id value for field " + field.name + ": " + externalValue,
          new String[] {field.name});
    }

    ApexSObject matched = matches.get(0);
    if (matched != null && matched.id() != null && !matched.id().isBlank()) {
      record.withId(matched.id());
      return UpsertPath.UPDATE;
    }
    return UpsertPath.INSERT;
  }

  private static List<UpsertPlanRow> planUpsertRows(
      State state, List<ApexSObject> normalized, String externalIdFieldName) {
    List<UpsertPlanRow> plan = new ArrayList<>(normalized.size());
    for (int i = 0; i < normalized.size(); i += 1) {
      ApexSObject record = requireRecord(normalized.get(i));
      UpsertPath path = resolveUpsertPath(state, record, externalIdFieldName);
      ApexSObject oldSnapshot =
          path == UpsertPath.UPDATE ? snapshotActiveRow(state, record, "upsert") : null;
      plan.add(new UpsertPlanRow(i, record, path, oldSnapshot));
    }
    return plan;
  }

  private static List<ApexSObject> upsertPlanNewRows(List<UpsertPlanRow> plan, UpsertPath path) {
    List<ApexSObject> out = new ArrayList<>();
    for (UpsertPlanRow row : plan) {
      if (row.path == path) {
        out.add(row.record);
      }
    }
    return out;
  }

  private static List<ApexSObject> upsertPlanOldRows(List<UpsertPlanRow> plan) {
    List<ApexSObject> out = new ArrayList<>();
    for (UpsertPlanRow row : plan) {
      if (row.path == UpsertPath.UPDATE && row.oldSnapshot != null) {
        out.add(row.oldSnapshot);
      }
    }
    return out;
  }

  private static String deleteOne(State state, ApexSObject raw) {
    ApexSObject record = requireRecord(raw);
    String id = requireId(record, "delete");

    Map<String, ApexSObject> activeBucket = state.active.get(record.type());
    if (activeBucket == null || !activeBucket.containsKey(id)) {
      throw new IllegalArgumentException("record not found for delete: " + record.type() + "#" + id);
    }

    ApexSObject removed = activeBucket.remove(id);
    if (removed != null) {
      removed.set("IsDeleted", Boolean.TRUE);
    }
    state.deleted.computeIfAbsent(record.type(), ignored -> new LinkedHashMap<>()).put(id, removed);
    syncRelatedRollups(state, removed, null);
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

    ApexSObject restored = deletedBucket.remove(id);
    if (restored != null) {
      restored.set("IsDeleted", Boolean.FALSE);
    }
    activeBucket.put(id, restored);
    syncRelatedRollups(state, null, restored);
    return id;
  }

  private static Database.MergeResult mergeOne(
      State state, ApexSObject rawMaster, List<ApexSObject> rawDuplicates) {
    ApexSObject master = requireRecord(rawMaster);
    validateForUpdate(state, master);
    String masterId = requireId(master, "merge");
    ApexSObject masterOld = snapshotActiveRow(state, master, "merge");
    MergePlan plan = planMerge(state, master, masterId, rawDuplicates);

    dispatchBefore(state, DmlVerb.UPDATE, List.of(master), List.of(masterOld));
    dispatchBefore(state, DmlVerb.DELETE, null, plan.duplicateOldRows);

    String mergedId = updateOne(state, master);
    for (ApexSObject duplicateDelete : plan.duplicateDeleteRows) {
      deleteOne(state, duplicateDelete);
    }
    RelatedReparentPlan relatedPlan =
        planRelatedReparent(state, master.type(), mergedId, plan.duplicateMergedIds);
    List<ApexSObject> relatedAfter = applyRelatedReparent(state, relatedPlan);
    String[] updatedRelatedIds = collectSortedIds(relatedAfter);

    ApexSObject masterNew = snapshotActiveRow(state, master, "merge");
    dispatchAfter(DmlVerb.UPDATE, List.of(masterNew), List.of(masterOld));
    dispatchAfter(DmlVerb.DELETE, null, plan.duplicateOldRows);

    return mergeSuccess(mergedId, plan.duplicateMergedIds, updatedRelatedIds);
  }

  private static MergePlan planMerge(
      State state, ApexSObject master, String masterId, List<ApexSObject> rawDuplicates) {
    if (rawDuplicates == null || rawDuplicates.isEmpty()) {
      throw new IllegalArgumentException("merge requires at least one duplicate record");
    }
    if (rawDuplicates.size() > 2) {
      throw new IllegalArgumentException("merge supports at most two duplicate records");
    }

    List<ApexSObject> duplicateDeleteRows = new ArrayList<>(rawDuplicates.size());
    List<ApexSObject> duplicateOldRows = new ArrayList<>(rawDuplicates.size());
    List<String> duplicateMergedIds = new ArrayList<>(rawDuplicates.size());
    List<String> seenDuplicateIds = new ArrayList<>(rawDuplicates.size());

    for (ApexSObject rawDuplicate : rawDuplicates) {
      ApexSObject duplicate = requireRecord(rawDuplicate);
      if (!duplicate.type().equalsIgnoreCase(master.type())) {
        throw new IllegalArgumentException(
            "merge requires same sobject type: master="
                + master.type()
                + " duplicate="
                + duplicate.type());
      }

      String duplicateId = requireId(duplicate, "merge");
      if (duplicateId.equalsIgnoreCase(masterId)) {
        throw new IllegalArgumentException("duplicate id in merge equals master id: " + duplicateId);
      }
      for (String seenId : seenDuplicateIds) {
        if (seenId.equalsIgnoreCase(duplicateId)) {
          throw new IllegalArgumentException("duplicate id in merge: " + duplicateId);
        }
      }
      seenDuplicateIds.add(duplicateId);
      duplicateMergedIds.add(duplicateId);

      duplicateOldRows.add(snapshotActiveRow(state, duplicate, "merge"));
      duplicateDeleteRows.add(ApexSObject.of(duplicate.type()).withId(duplicateId));
    }

    return new MergePlan(duplicateDeleteRows, duplicateOldRows, duplicateMergedIds);
  }

  private static List<ApexSObject> beforeOldRecords(
      State state, DmlVerb verb, List<ApexSObject> records) {
    return switch (verb) {
      case UPDATE, DELETE -> snapshotActiveRows(state, records, verb.operationName);
      case INSERT, UNDELETE, UPSERT -> List.of();
    };
  }

  private static List<ApexSObject> afterNewRecords(
      State state, DmlVerb verb, List<ApexSObject> records) {
    return switch (verb) {
      case INSERT, UPDATE, UNDELETE -> snapshotActiveRows(state, records, verb.operationName);
      case DELETE, UPSERT -> List.of();
    };
  }

  private static List<ApexSObject> snapshotActiveRows(
      State state, List<ApexSObject> records, String operationName) {
    if (records == null || records.isEmpty()) {
      return List.of();
    }
    List<ApexSObject> out = new ArrayList<>(records.size());
    for (ApexSObject record : records) {
      out.add(snapshotActiveRow(state, record, operationName));
    }
    return out;
  }

  private static ApexSObject snapshotActiveRow(State state, ApexSObject record, String operationName) {
    ApexSObject source = requireRecord(record);
    String id = requireId(source, operationName);
    Map<String, ApexSObject> bucket = state.active.get(source.type());
    if (bucket == null || !bucket.containsKey(id)) {
      throw new IllegalArgumentException(
          "record not found for " + operationName + ": " + source.type() + "#" + id);
    }
    return bucket.get(id).copy();
  }

  private static void dispatchBefore(
      State state, DmlVerb verb, List<ApexSObject> newRecords, List<ApexSObject> oldRecords) {
    switch (verb) {
      case INSERT -> dispatchTrigger(true, Trigger.Operation.INSERT, newRecords, null);
      case UPDATE ->
          {
            List<ApexSObject> triggerNew = materializeBeforeUpdateRows(state, newRecords, oldRecords);
            dispatchTrigger(true, Trigger.Operation.UPDATE, triggerNew, oldRecords);
            applyBeforeUpdateMutations(newRecords, triggerNew);
          }
      case DELETE -> dispatchTrigger(true, Trigger.Operation.DELETE, null, oldRecords);
      case UNDELETE, UPSERT -> {}
    }
  }

  private static List<ApexSObject> materializeBeforeUpdateRows(
      State state, List<ApexSObject> newRecords, List<ApexSObject> oldRecords) {
    if (newRecords == null || newRecords.isEmpty()) {
      return List.of();
    }
    Map<String, ApexSObject> oldByKey = new LinkedHashMap<>();
    if (oldRecords != null) {
      for (ApexSObject oldRow : oldRecords) {
        if (oldRow == null || oldRow.type() == null || oldRow.id() == null || oldRow.id().isBlank()) {
          continue;
        }
        oldByKey.put(oldRow.type().toLowerCase() + "#" + oldRow.id().toLowerCase(), oldRow);
      }
    }

    List<ApexSObject> out = new ArrayList<>(newRecords.size());
    for (ApexSObject newRow : newRecords) {
      if (newRow == null) {
        continue;
      }
      ApexSObject merged = null;
      String id = newRow.id();
      if (newRow.type() != null && id != null && !id.isBlank()) {
        merged = oldByKey.get(newRow.type().toLowerCase() + "#" + id.toLowerCase());
        if (merged != null) {
          merged = merged.copy();
        }
      }
      if (merged == null) {
        try {
          merged = snapshotActiveRow(state, newRow, "update");
        } catch (RuntimeException ignored) {
          // fall through
        }
      }
      if (merged == null) {
        merged = ApexSObject.of(newRow.type());
        if (id != null && !id.isBlank()) {
          merged.withId(id);
        }
      }
      for (Map.Entry<String, Object> field : newRow.fields().entrySet()) {
        merged.set(field.getKey(), field.getValue());
      }
      if (merged.id() == null && id != null && !id.isBlank()) {
        merged.withId(id);
      }
      out.add(merged);
    }
    return out;
  }

  private static void applyBeforeUpdateMutations(
      List<ApexSObject> targetRows, List<ApexSObject> triggerRows) {
    if (targetRows == null || triggerRows == null || targetRows.isEmpty() || triggerRows.isEmpty()) {
      return;
    }
    int count = Math.min(targetRows.size(), triggerRows.size());
    for (int i = 0; i < count; i += 1) {
      ApexSObject target = targetRows.get(i);
      ApexSObject source = triggerRows.get(i);
      if (target == null || source == null) {
        continue;
      }
      if (source.id() != null && !source.id().isBlank()) {
        target.withId(source.id());
      }
      for (Map.Entry<String, Object> field : source.fields().entrySet()) {
        target.set(field.getKey(), field.getValue());
      }
    }
  }

  private static void dispatchAfter(
      DmlVerb verb, List<ApexSObject> newRecords, List<ApexSObject> oldRecords) {
    switch (verb) {
      case INSERT -> dispatchTrigger(false, Trigger.Operation.INSERT, newRecords, null);
      case UPDATE -> dispatchTrigger(false, Trigger.Operation.UPDATE, newRecords, oldRecords);
      case DELETE -> dispatchTrigger(false, Trigger.Operation.DELETE, null, oldRecords);
      case UNDELETE -> dispatchTrigger(false, Trigger.Operation.UNDELETE, newRecords, null);
      case UPSERT -> {}
    }
  }

  private static void dispatchTrigger(
      boolean before,
      Trigger.Operation operation,
      List<ApexSObject> newRecords,
      List<ApexSObject> oldRecords) {
    List<String> types = collectTypes(newRecords, oldRecords);
    for (String type : types) {
      List<ApexSObject> typeNew = filterByType(newRecords, type);
      List<ApexSObject> typeOld = filterByType(oldRecords, type);
      List<ApexSObject> dispatchNew = typeNew.isEmpty() ? null : typeNew;
      List<ApexSObject> dispatchOld = typeOld.isEmpty() ? null : typeOld;
      if (before) {
        Trigger.dispatchBefore(type, operation, dispatchNew, dispatchOld);
      } else {
        Trigger.dispatchAfter(type, operation, dispatchNew, dispatchOld);
      }
    }
  }

  private static List<String> collectTypes(List<ApexSObject> newRecords, List<ApexSObject> oldRecords) {
    List<String> out = new ArrayList<>();
    addTypes(out, newRecords);
    addTypes(out, oldRecords);
    return out;
  }

  private static void addTypes(List<String> out, List<ApexSObject> records) {
    if (records == null || records.isEmpty()) {
      return;
    }
    for (ApexSObject record : records) {
      if (record == null || record.type() == null) {
        continue;
      }
      String type = record.type();
      boolean exists = false;
      for (String item : out) {
        if (item.equalsIgnoreCase(type)) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        out.add(type);
      }
    }
  }

  private static List<ApexSObject> filterByType(List<ApexSObject> records, String type) {
    if (records == null || records.isEmpty() || type == null) {
      return List.of();
    }
    List<ApexSObject> out = new ArrayList<>();
    for (ApexSObject record : records) {
      if (record != null && record.type().equalsIgnoreCase(type)) {
        out.add(record);
      }
    }
    return out;
  }

  private static List<ApexSObject> scan(QuerySpec spec, boolean countOnly) {
    if (spec != null
        && isType(spec.sobjectType, "DatedConversionRate")
        && !UserInfo.isMultiCurrencyOrganization()) {
      throw new QueryException("sObject type 'DatedConversionRate' is not supported");
    }

    State state = STATE.get();
    Map<String, ApexSObject> activeBucket = findBucketByType(state.active, spec.sobjectType);
    Map<String, ApexSObject> deletedBucket =
        spec != null && spec.includeAllRows
            ? findBucketByType(state.deleted, spec.sobjectType)
            : null;
    boolean aggregateQuery = isAggregateQuery(spec);
    boolean hasActiveRows = activeBucket != null && !activeBucket.isEmpty();
    boolean hasDeletedRows = deletedBucket != null && !deletedBucket.isEmpty();
    if (spec != null && isType(spec.sobjectType, "RecordType") && !hasActiveRows && !hasDeletedRows) {
      List<ApexSObject> syntheticRecordTypes = synthesizeRecordTypeRows();
      if (!syntheticRecordTypes.isEmpty()) {
        List<ApexSObject> filtered = new ArrayList<>();
        for (ApexSObject row : syntheticRecordTypes) {
          if (!matchesWhere(row, spec.whereExpr)) {
            continue;
          }
          filtered.add(row);
        }
        if (!countOnly && aggregateQuery) {
          return scanAggregate(spec, filtered);
        }
        return applyOrderingAndPaging(spec, filtered, countOnly);
      }
    }
    if (!hasActiveRows && !hasDeletedRows) {
      if (!countOnly && aggregateQuery && (spec.groupByFields == null || spec.groupByFields.isEmpty())) {
        ApexSObject aggregate = buildAggregateRow(spec, List.of(), List.of());
        if (aggregate == null) {
          return List.of();
        }
        return applyOrderingAndPaging(spec, new ArrayList<>(List.of(aggregate)), false);
      }
      return applyOrderingAndPaging(spec, new ArrayList<>(), countOnly);
    }

    List<ApexSObject> out = new ArrayList<>();
    if (hasActiveRows) {
      for (ApexSObject row : activeBucket.values()) {
        if (!matchesWhere(row, spec.whereExpr)) {
          continue;
        }
        out.add(row);
      }
    }
    if (hasDeletedRows) {
      for (ApexSObject row : deletedBucket.values()) {
        if (!matchesWhere(row, spec.whereExpr)) {
          continue;
        }
        out.add(row);
      }
    }

    if (!countOnly && aggregateQuery) {
      return scanAggregate(spec, out);
    }
    return applyOrderingAndPaging(spec, out, countOnly);
  }

  private static List<ApexSObject> synthesizeRecordTypeRows() {
    Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
    if (globalDescribe == null || globalDescribe.isEmpty()) {
      return new ArrayList<>(List.of(Schema.DefaultRecordTypeInfo.defaultFor("SObject")));
    }
    Set<String> seenTypeNames = new LinkedHashSet<>();
    Set<String> seenRecordTypeIds = new LinkedHashSet<>();
    List<ApexSObject> out = new ArrayList<>();
    for (Schema.SObjectType token : globalDescribe.values()) {
      if (token == null || token.getName() == null || token.getName().isBlank()) {
        continue;
      }
      String typeName = token.getName().trim();
      if (typeName.equalsIgnoreCase("RecordType")) {
        continue;
      }
      String key = typeName.toLowerCase();
      if (!seenTypeNames.add(key)) {
        continue;
      }
      List<apexemu.runtime.RecordTypeInfo> recordTypeInfos = token.getDescribe().getRecordTypeInfos();
      if (recordTypeInfos == null || recordTypeInfos.isEmpty()) {
        ApexSObject fallback = Schema.DefaultRecordTypeInfo.defaultFor(typeName);
        if (fallback != null && fallback.getAs("Id") != null && seenRecordTypeIds.add(fallback.getAs("Id"))) {
          out.add(fallback);
        }
        continue;
      }
      for (apexemu.runtime.RecordTypeInfo info : recordTypeInfos) {
        if (info == null) {
          continue;
        }
        ApexSObject row = info.getRecordTypeInfo();
        if (row == null) {
          continue;
        }
        String recordTypeId = row.getAs("Id");
        if (recordTypeId == null || !seenRecordTypeIds.add(recordTypeId)) {
          continue;
        }
        out.add(row);
      }
    }
    if (out.isEmpty()) {
      out.add(Schema.DefaultRecordTypeInfo.defaultFor("SObject"));
    }
    return out;
  }

  private static boolean isAggregateQuery(QuerySpec spec) {
    if (spec == null) {
      return false;
    }
    if (spec.selectSpec != null && spec.selectSpec.hasAggregate) {
      return true;
    }
    return spec.groupByFields != null && !spec.groupByFields.isEmpty();
  }

  private static List<ApexSObject> applyOrderingAndPaging(
      QuerySpec spec, List<ApexSObject> rows, boolean countOnly) {
    List<ApexSObject> out = rows == null ? new ArrayList<>() : rows;

    if (!countOnly && spec.orderByKeys != null && !spec.orderByKeys.isEmpty()) {
      out.sort(
          (left, right) -> {
            for (OrderByKey key : spec.orderByKeys) {
              Object leftValue = resolveFieldValue(left, key.field);
              Object rightValue = resolveFieldValue(right, key.field);
              boolean nullsFirst = effectiveNullsFirst(key);
              int nullOrderCompared = compareNullOrder(leftValue, rightValue, nullsFirst);
              if (nullOrderCompared != 0) {
                return nullOrderCompared;
              }
              int compared = compareValues(leftValue, rightValue);
              if (compared != 0) {
                return key.descending ? -compared : compared;
              }
            }
            return 0;
          });
    }

    int offset = Math.max(0, spec.offset);
    if (offset > 0) {
      if (offset >= out.size()) {
        return new ArrayList<>();
      }
      out = new ArrayList<>(out.subList(offset, out.size()));
    }

    if (spec.limit > 0 && out.size() > spec.limit) {
      out = new ArrayList<>(out.subList(0, spec.limit));
    }
    return out;
  }

  private static List<ApexSObject> scanAggregate(QuerySpec spec, List<ApexSObject> filteredRows) {
    List<String> groupFields = spec.groupByFields == null ? List.of() : spec.groupByFields;
    LinkedHashMap<GroupKey, List<ApexSObject>> groups = new LinkedHashMap<>();

    if (groupFields.isEmpty()) {
      groups.put(new GroupKey(List.of()), filteredRows == null ? List.of() : filteredRows);
    } else if (filteredRows != null && !filteredRows.isEmpty()) {
      for (ApexSObject row : filteredRows) {
        List<Object> keyValues = new ArrayList<>(groupFields.size());
        for (String field : groupFields) {
          keyValues.add(resolveFieldValue(row, field));
        }
        GroupKey key = new GroupKey(keyValues);
        groups.computeIfAbsent(key, ignored -> new ArrayList<>()).add(row);
      }
    }

    List<ApexSObject> out = new ArrayList<>();
    for (Map.Entry<GroupKey, List<ApexSObject>> entry : groups.entrySet()) {
      List<ApexSObject> groupRows = entry.getValue() == null ? List.of() : entry.getValue();
      List<Object> keyValues = entry.getKey() == null ? List.of() : entry.getKey().values;
      if (!matchesHaving(groupRows, keyValues, spec.havingExpr)) {
        continue;
      }
      ApexSObject aggregate = buildAggregateRow(spec, groupRows, keyValues);
      if (aggregate != null) {
        out.add(aggregate);
      }
    }

    return applyOrderingAndPaging(spec, out, false);
  }

  private static ApexSObject buildAggregateRow(
      QuerySpec spec, List<ApexSObject> groupRows, List<Object> groupKeyValues) {
    if (spec == null || spec.selectSpec == null || spec.selectSpec.items == null) {
      return null;
    }

    AggregateResult row = new AggregateResult();

    if (spec.groupByFields != null && !spec.groupByFields.isEmpty()) {
      for (int i = 0; i < spec.groupByFields.size(); i += 1) {
        String field = spec.groupByFields.get(i);
        Object value = i < groupKeyValues.size() ? groupKeyValues.get(i) : null;
        row.set(field, value);
      }
    }

    for (SelectItem item : spec.selectSpec.items) {
      Object value = evaluateSelectItem(item, groupRows, spec.groupByFields, groupKeyValues);
      row.set(item.outputName, value);
    }
    return row;
  }

  private static boolean matchesHaving(
      List<ApexSObject> groupRows, List<Object> groupKeyValues, HavingExpr havingExpr) {
    if (havingExpr == null) {
      return true;
    }
    if (havingExpr instanceof HavingPredicateExpr predicate) {
      return matchesHavingClause(groupRows, groupKeyValues, predicate.clause);
    }
    if (havingExpr instanceof HavingNotExpr notExpr) {
      return !matchesHaving(groupRows, groupKeyValues, notExpr.inner);
    }
    if (havingExpr instanceof HavingLogicalExpr logicalExpr) {
      if (logicalExpr.operator == LogicalOperator.AND) {
        for (HavingExpr term : logicalExpr.terms) {
          if (!matchesHaving(groupRows, groupKeyValues, term)) {
            return false;
          }
        }
        return true;
      }
      for (HavingExpr term : logicalExpr.terms) {
        if (matchesHaving(groupRows, groupKeyValues, term)) {
          return true;
        }
      }
      return false;
    }
    return false;
  }

  private static boolean matchesHavingClause(
      List<ApexSObject> groupRows, List<Object> groupKeyValues, HavingClause clause) {
    Object left = resolveHavingOperand(groupRows, groupKeyValues, clause.operand);
    return switch (clause.operator) {
      case "=" -> compareEquality(left, clause.literal);
      case "!=" -> !compareEquality(left, clause.literal);
      case ">" -> compareRange(left, clause.literal, ">");
      case ">=" -> compareRange(left, clause.literal, ">=");
      case "<" -> compareRange(left, clause.literal, "<");
      case "<=" -> compareRange(left, clause.literal, "<=");
      default -> false;
    };
  }

  private static Object resolveHavingOperand(
      List<ApexSObject> groupRows, List<Object> groupKeyValues, HavingOperand operand) {
    if (operand instanceof HavingFieldOperand fieldOperand) {
      String field = fieldOperand.field;
      if (fieldOperand.groupFieldIndex >= 0
          && groupKeyValues != null
          && fieldOperand.groupFieldIndex < groupKeyValues.size()) {
        return groupKeyValues.get(fieldOperand.groupFieldIndex);
      }
      if (groupRows == null || groupRows.isEmpty()) {
        return null;
      }
      ApexSObject first = groupRows.get(0);
      return resolveFieldValue(first, field);
    }
    if (operand instanceof HavingAggregateOperand aggregateOperand) {
      return evaluateAggregate(
          aggregateOperand.function, aggregateOperand.field, aggregateOperand.countAll, groupRows);
    }
    return null;
  }

  private static Object evaluateSelectItem(
      SelectItem item,
      List<ApexSObject> groupRows,
      List<String> groupByFields,
      List<Object> groupKeyValues) {
    if (item.kind == SelectItemKind.FIELD) {
      int groupFieldIndex = indexOfIgnoreCase(groupByFields, item.field);
      if (groupFieldIndex >= 0
          && groupKeyValues != null
          && groupFieldIndex < groupKeyValues.size()) {
        return groupKeyValues.get(groupFieldIndex);
      }
      if (groupRows == null || groupRows.isEmpty()) {
        return null;
      }
      ApexSObject first = groupRows.get(0);
      return resolveFieldValue(first, item.field);
    }
    if (item.kind == SelectItemKind.CHILD_SUBQUERY) {
      return List.of();
    }
    return evaluateAggregate(item.aggregateFunction, item.field, item.countAll, groupRows);
  }

  private static void attachChildSubqueryRows(
      QuerySpec spec, ApexSObject sourceRow, ApexSObject projectedRow) {
    if (spec == null
        || spec.selectSpec == null
        || spec.selectSpec.items == null
        || sourceRow == null
        || projectedRow == null) {
      return;
    }
    for (SelectItem item : spec.selectSpec.items) {
      if (item.kind != SelectItemKind.CHILD_SUBQUERY || item.childSubquery == null) {
        continue;
      }
      List<ApexSObject> childRows = executeChildSubqueryForParent(item.childSubquery, sourceRow);
      projectedRow.set(item.outputName, childRows);
    }
  }

  private static List<ApexSObject> executeChildSubqueryForParent(
      ChildSubquerySpec childSubquery, ApexSObject parentRow) {
    if (childSubquery == null || parentRow == null) {
      return List.of();
    }
    String parentId = normalizeId(parentRow.id());
    if (parentId == null) {
      return List.of();
    }

    QuerySpec scoped =
        withAdditionalWhere(
            childSubquery.querySpec,
            new WhereClause(childSubquery.parentLinkField, "=", parentId));
    List<ApexSObject> scopedRows = scan(scoped, false);
    if (!scopedRows.isEmpty()) {
      return copyRows(scopedRows);
    }

    // Fallback: when relation->foreign-key inference misses, scan once and detect likely reference fields.
    List<ApexSObject> allRows = scan(childSubquery.querySpec, false);
    List<ApexSObject> fallback = new ArrayList<>();
    for (ApexSObject child : allRows) {
      if (matchesAnyReferenceField(child, parentId)) {
        fallback.add(child);
      }
    }
    return copyRows(applyOrderingAndPaging(childSubquery.querySpec, fallback, false));
  }

  private static QuerySpec withAdditionalWhere(QuerySpec spec, WhereClause additionalClause) {
    if (spec == null || additionalClause == null) {
      return spec;
    }
    WhereExpr additionalExpr = new WherePredicateExpr(additionalClause);
    WhereExpr combined =
        spec.whereExpr == null
            ? additionalExpr
            : new WhereLogicalExpr(LogicalOperator.AND, List.of(spec.whereExpr, additionalExpr));
    return new QuerySpec(
        spec.sobjectType,
        spec.selectSpec,
        combined,
        spec.groupByFields,
        spec.havingExpr,
        spec.orderByKeys,
        spec.limit,
        spec.offset,
        spec.includeAllRows);
  }

  private static boolean matchesAnyReferenceField(ApexSObject row, String parentId) {
    if (row == null || parentId == null || parentId.isBlank()) {
      return false;
    }
    for (Map.Entry<String, Object> field : row.fields().entrySet()) {
      String name = field.getKey();
      if (name == null) {
        continue;
      }
      boolean candidateName =
          name.length() > 2 && (name.endsWith("Id") || name.endsWith("__c"));
      if (!candidateName) {
        continue;
      }
      if (compareEquality(field.getValue(), parentId)) {
        return true;
      }
    }
    return false;
  }

  private static List<ApexSObject> copyRows(List<ApexSObject> rows) {
    if (rows == null || rows.isEmpty()) {
      return List.of();
    }
    List<ApexSObject> out = new ArrayList<>(rows.size());
    for (ApexSObject row : rows) {
      out.add(row == null ? null : row.copy());
    }
    return out;
  }

  private static Object evaluateAggregate(
      AggregateFunction function, String field, boolean countAll, List<ApexSObject> rows) {
    List<ApexSObject> source = rows == null ? List.of() : rows;
    if (function == AggregateFunction.COUNT) {
      if (countAll || field == null || field.isBlank()) {
        return (long) source.size();
      }
      long count = 0L;
      for (ApexSObject row : source) {
        if (resolveFieldValue(row, field) != null) {
          count += 1L;
        }
      }
      return count;
    }
    if (function == AggregateFunction.COUNT_DISTINCT) {
      if (field == null || field.isBlank()) {
        return 0L;
      }
      Set<Object> distinct = new HashSet<>();
      for (ApexSObject row : source) {
        if (row == null) {
          continue;
        }
        Object value = row.get(field);
        if (value != null) {
          distinct.add(value);
        }
      }
      return (long) distinct.size();
    }

    if (function == AggregateFunction.SUM || function == AggregateFunction.AVG) {
      double sum = 0.0;
      long count = 0L;
      for (ApexSObject row : source) {
        if (row == null) {
          continue;
        }
        Double numeric = toNumber(resolveFieldValue(row, field));
        if (numeric == null) {
          continue;
        }
        sum += numeric;
        count += 1L;
      }
      if (count == 0L) {
        return null;
      }
      if (function == AggregateFunction.SUM) {
        return sum;
      }
      return sum / (double) count;
    }

    if (function == AggregateFunction.MIN || function == AggregateFunction.MAX) {
      Object best = null;
      boolean found = false;
      for (ApexSObject row : source) {
        if (row == null) {
          continue;
        }
        Object value = resolveFieldValue(row, field);
        if (value == null) {
          continue;
        }
        if (!found) {
          best = value;
          found = true;
          continue;
        }
        int compared = compareValues(value, best);
        if ((function == AggregateFunction.MIN && compared < 0)
            || (function == AggregateFunction.MAX && compared > 0)) {
          best = value;
        }
      }
      return found ? best : null;
    }

    return null;
  }

  private static boolean matchesWhere(ApexSObject row, WhereExpr whereExpr) {
    if (whereExpr == null) {
      return true;
    }
    if (whereExpr instanceof WherePredicateExpr predicateExpr) {
      return matchesClause(row, predicateExpr.clause);
    }
    if (whereExpr instanceof WhereNotExpr notExpr) {
      return !matchesWhere(row, notExpr.inner);
    }
    if (whereExpr instanceof WhereLogicalExpr logicalExpr) {
      if (logicalExpr.operator == LogicalOperator.AND) {
        for (WhereExpr term : logicalExpr.terms) {
          if (!matchesWhere(row, term)) {
            return false;
          }
        }
        return true;
      }
      for (WhereExpr term : logicalExpr.terms) {
        if (matchesWhere(row, term)) {
          return true;
        }
      }
      return false;
    }
    return false;
  }

  private static boolean matchesClause(ApexSObject row, WhereClause clause) {
    // Unresolved bind variables (e.g. :id from Database.query with UTIL_Query)
    // are treated as matching everything — the caller intended a bind but
    // the emulation received a raw SOQL string without bind map.
    if (clause.literal instanceof String litStr && litStr.startsWith(":")) {
      return true;
    }
    Object value = resolveFieldValue(row, clause.field);
    return switch (clause.operator) {
      case "=" -> compareEquality(value, clause.literal);
      case "!=" -> !compareEquality(value, clause.literal);
      case ">" -> compareRange(value, clause.literal, ">");
      case ">=" -> compareRange(value, clause.literal, ">=");
      case "<" -> compareRange(value, clause.literal, "<");
      case "<=" -> compareRange(value, clause.literal, "<=");
      case "in" -> compareIn(value, clause.literal);
      case "not in" -> !compareIn(value, clause.literal);
      case "like" -> compareLike(value, clause.literal);
      case "is null" -> value == null;
      case "is not null" -> value != null;
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

    if (whereLiteral instanceof DateRangeLiteral dateRangeLiteral) {
      LocalDate valueDate = toDateValue(value);
      return valueDate != null && dateRangeLiteral.contains(valueDate);
    }

    LocalDate literalDate = toDateValue(whereLiteral);
    LocalDate valueDate = toDateValue(value);
    if (literalDate != null && valueDate != null) {
      return literalDate.isEqual(valueDate);
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
    if (whereLiteral instanceof Number literalNum) {
      Double valueNum = toNumber(value);
      if (valueNum != null) {
        return Double.compare(literalNum.doubleValue(), valueNum.doubleValue()) == 0;
      }
    }
    if (value instanceof Number valueNum) {
      Double literalNum = toNumber(whereLiteral);
      if (literalNum != null) {
        return Double.compare(valueNum.doubleValue(), literalNum.doubleValue()) == 0;
      }
    }
    return Objects.equals(String.valueOf(whereLiteral), String.valueOf(value));
  }

  private static boolean compareRange(Object value, Object whereLiteral, String operator) {
    if (value == null || whereLiteral == null) {
      return false;
    }

    if (whereLiteral instanceof DateRangeLiteral dateRangeLiteral) {
      LocalDate valueDate = toDateValue(value);
      if (valueDate == null) {
        return false;
      }
      return switch (operator) {
        case ">" -> valueDate.isAfter(dateRangeLiteral.endInclusive());
        case ">=" -> !valueDate.isBefore(dateRangeLiteral.startInclusive());
        case "<" -> valueDate.isBefore(dateRangeLiteral.startInclusive());
        case "<=" -> !valueDate.isAfter(dateRangeLiteral.endInclusive());
        default -> false;
      };
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

    LocalDate leftDate = toDateValue(left);
    LocalDate rightDate = toDateValue(right);
    if (leftDate != null && rightDate != null) {
      return leftDate.compareTo(rightDate);
    }

    String leftValue = String.valueOf(left);
    String rightValue = String.valueOf(right);
    return leftValue.compareTo(rightValue);
  }

  private static int compareNullOrder(Object left, Object right, boolean nullsFirst) {
    if (left == null && right == null) {
      return 0;
    }
    if (left == null) {
      return nullsFirst ? -1 : 1;
    }
    if (right == null) {
      return nullsFirst ? 1 : -1;
    }
    return 0;
  }

  private static boolean effectiveNullsFirst(OrderByKey key) {
    if (key != null && key.nullsFirst != null) {
      return key.nullsFirst;
    }
    Database.NullOrderDefault mode = normalizeNullOrderDefault(CONFIG.get().nullOrderDefault);
    boolean descending = key != null && key.descending;
    return switch (mode) {
      case FIRST -> true;
      case LAST -> false;
      case DIRECTIONAL -> !descending;
    };
  }

  private static Database.NullOrderDefault normalizeNullOrderDefault(Database.NullOrderDefault mode) {
    return mode == null ? Database.NullOrderDefault.FIRST : mode;
  }

  @SuppressWarnings("unchecked")
  private static boolean compareIn(Object value, Object whereLiteral) {
    if (whereLiteral instanceof SemiJoinLiteral semiJoinLiteral) {
      return compareInSemiJoin(value, semiJoinLiteral);
    }
    if (!(whereLiteral instanceof List<?> literalList)) {
      return false;
    }
    for (Object item : literalList) {
      if (compareEquality(value, item)) {
        return true;
      }
    }
    return false;
  }

  private static boolean compareInSemiJoin(Object value, SemiJoinLiteral semiJoinLiteral) {
    if (semiJoinLiteral == null) {
      return false;
    }

    State state = STATE.get();
    List<Object> candidates = state.semiJoinCache.get(semiJoinLiteral);
    if (candidates == null) {
      candidates = evaluateSemiJoinValues(semiJoinLiteral);
      state.semiJoinCache.put(semiJoinLiteral, candidates);
    }
    for (Object candidate : candidates) {
      if (compareEquality(value, candidate)) {
        return true;
      }
    }
    return false;
  }

  private static List<Object> evaluateSemiJoinValues(SemiJoinLiteral semiJoinLiteral) {
    List<ApexSObject> rows = scan(semiJoinLiteral.querySpec, false);
    List<Object> out = new ArrayList<>(rows.size());
    for (ApexSObject row : rows) {
      out.add(resolveFieldValue(row, semiJoinLiteral.selectedField));
    }
    return out;
  }

  private static boolean compareLike(Object value, Object whereLiteral) {
    if (value == null || whereLiteral == null) {
      return false;
    }
    String candidate = String.valueOf(value);
    String pattern = String.valueOf(whereLiteral);
    String regex = toLikeRegex(pattern);
    try {
      return Pattern.compile(regex, Pattern.DOTALL | Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE)
          .matcher(candidate)
          .matches();
    } catch (PatternSyntaxException error) {
      return false;
    }
  }

  private static Object resolveFieldValue(ApexSObject row, String fieldPath) {
    if (row == null || fieldPath == null || fieldPath.isBlank()) {
      return null;
    }

    DatePartField datePartField = parseDatePartFieldExpression(fieldPath);
    if (datePartField != null) {
      Object sourceValue = resolveFieldValue(row, datePartField.fieldPath());
      return evaluateDatePartField(datePartField.functionName(), sourceValue);
    }

    Object direct = row.get(fieldPath);
    if (!fieldPath.contains(".")) {
      return direct;
    }
    if (direct != null || row.hasField(fieldPath)) {
      return direct;
    }

    ApexSObject current = row;
    String[] segments = fieldPath.split("\\.");
    for (int i = 0; i < segments.length; i += 1) {
      String segment = segments[i] == null ? "" : segments[i].trim();
      if (segment.isEmpty()) {
        return null;
      }

      boolean last = i == segments.length - 1;
      if (last) {
        return current == null ? null : current.get(segment);
      }
      current = resolveRelationshipHop(current, segment);
      if (current == null) {
        return null;
      }
    }
    return null;
  }

  private static Object evaluateDatePartField(String functionName, Object sourceValue) {
    if (functionName == null || functionName.isBlank() || sourceValue == null) {
      return null;
    }
    LocalDate dateValue = toDateValue(sourceValue);
    if (dateValue == null) {
      return null;
    }
    if ("CALENDAR_YEAR".equalsIgnoreCase(functionName)) {
      return dateValue.getYear();
    }
    return null;
  }

  private static ApexSObject resolveRelationshipHop(ApexSObject row, String relationshipSegment) {
    if (row == null || relationshipSegment == null || relationshipSegment.isBlank()) {
      return null;
    }

    Object embedded = row.get(relationshipSegment);
    if (embedded instanceof ApexSObject embeddedRow) {
      return embeddedRow;
    }
    if (embedded instanceof String embeddedId && !embeddedId.isBlank()) {
      ApexSObject related = findActiveRowById(embeddedId);
      if (related != null) {
        return related;
      }
    }

    String referenceField = inferReferenceField(row.type(), relationshipSegment);
    if (referenceField == null) {
      return null;
    }
    Object referenceValue = row.get(referenceField);
    if (!(referenceValue instanceof String relatedId) || relatedId.isBlank()) {
      return null;
    }
    return findActiveRowById(relatedId);
  }

  private static String inferReferenceField(String rowType, String relationshipSegment) {
    if (relationshipSegment == null || relationshipSegment.isBlank()) {
      return null;
    }
    String schemaField = Schema.resolveReferenceField(rowType, relationshipSegment);
    if (schemaField != null && !schemaField.isBlank()) {
      return schemaField;
    }
    String normalized = relationshipSegment.trim();
    if (normalized.length() > 3
        && normalized.regionMatches(true, normalized.length() - 3, "__r", 0, 3)) {
      return normalized.substring(0, normalized.length() - 3) + "__c";
    }
    return normalized + "Id";
  }

  private static ApexSObject findActiveRowById(String id) {
    if (id == null || id.isBlank()) {
      return null;
    }
    State state = STATE.get();
    for (Map<String, ApexSObject> bucket : state.active.values()) {
      for (Map.Entry<String, ApexSObject> entry : bucket.entrySet()) {
        if (entry.getKey() != null && entry.getKey().equalsIgnoreCase(id)) {
          return entry.getValue();
        }
        ApexSObject row = entry.getValue();
        if (row != null && row.id() != null && row.id().equalsIgnoreCase(id)) {
          return row;
        }
      }
    }
    return null;
  }

  private static ApexSObject findActiveRowByIdAndType(String id, String type) {
    if (id == null || id.isBlank() || type == null || type.isBlank()) {
      return null;
    }
    State state = STATE.get();
    for (Map.Entry<String, Map<String, ApexSObject>> bucketEntry : state.active.entrySet()) {
      String bucketType = bucketEntry.getKey();
      if (bucketType == null || !bucketType.equalsIgnoreCase(type)) {
        continue;
      }
      for (Map.Entry<String, ApexSObject> rowEntry : bucketEntry.getValue().entrySet()) {
        if (rowEntry.getKey() != null && rowEntry.getKey().equalsIgnoreCase(id)) {
          return rowEntry.getValue();
        }
        ApexSObject row = rowEntry.getValue();
        if (row != null && row.id() != null && row.id().equalsIgnoreCase(id)) {
          return row;
        }
      }
    }
    return null;
  }

  private static SoslSpec parseSoslSpec(String rawSosl) {
    if (rawSosl == null || rawSosl.isBlank()) {
      throw new IllegalArgumentException("SOSL cannot be blank");
    }
    String sosl = sanitize(rawSosl);
    Matcher matcher = SOSL_PATTERN.matcher(sosl);
    if (!matcher.matches()) {
      throw new IllegalArgumentException("unsupported SOSL syntax: " + rawSosl);
    }

    String term = extractSoslSearchTerm(matcher.group(1));
    boolean nameFieldsOnly = matcher.group(2) != null && matcher.group(2).equalsIgnoreCase("name");
    List<String> returningTypes = parseSoslReturningTypes(matcher.group(3), rawSosl);
    return new SoslSpec(term, nameFieldsOnly, returningTypes);
  }

  private static String extractSoslSearchTerm(String rawTerm) {
    if (rawTerm == null) {
      return "";
    }
    String term = rawTerm.trim();
    if (term.length() >= 2) {
      char first = term.charAt(0);
      char last = term.charAt(term.length() - 1);
      if ((first == '\'' && last == '\'') || (first == '"' && last == '"')) {
        term = term.substring(1, term.length() - 1);
      }
    }
    return term.replace("''", "'");
  }

  private static List<String> parseSoslReturningTypes(String rawReturning, String rawSosl) {
    if (rawReturning == null || rawReturning.isBlank()) {
      throw new IllegalArgumentException("SOSL RETURNING must not be empty: " + rawSosl);
    }
    List<String> segments = splitByComma(rawReturning.trim());
    List<String> out = new ArrayList<>();
    for (String segment : segments) {
      String item = segment == null ? "" : segment.trim();
      if (item.isEmpty()) {
        continue;
      }
      int openParen = item.indexOf('(');
      String typeName = openParen >= 0 ? item.substring(0, openParen).trim() : item;
      if (!typeName.isEmpty()) {
        out.add(typeName);
      }
    }
    if (out.isEmpty()) {
      throw new IllegalArgumentException("SOSL RETURNING must include at least one type: " + rawSosl);
    }
    return out;
  }

  private static boolean matchesSoslTerm(ApexSObject row, String rawTerm, boolean nameFieldsOnly) {
    if (row == null) {
      return false;
    }
    String term = normalizeSoslMatchToken(rawTerm);
    if (term.isEmpty()) {
      return true;
    }

    if (nameFieldsOnly) {
      Object nameValue = row.get("Name");
      if (valueMatchesSoslTerm(nameValue, term)) {
        return true;
      }
    }

    for (Map.Entry<String, Object> entry : row.fields().entrySet()) {
      String fieldName = entry.getKey();
      if (fieldName == null || fieldName.isBlank()) {
        continue;
      }
      if (nameFieldsOnly) {
        String normalizedField = fieldName.trim().toLowerCase();
        if (!normalizedField.contains("name")) {
          continue;
        }
      }
      if (valueMatchesSoslTerm(entry.getValue(), term)) {
        return true;
      }
    }
    return false;
  }

  private static String normalizeSoslMatchToken(String rawTerm) {
    if (rawTerm == null) {
      return "";
    }
    return rawTerm.replace("*", "").trim().toLowerCase();
  }

  private static boolean valueMatchesSoslTerm(Object value, String normalizedTerm) {
    if (value == null || normalizedTerm == null || normalizedTerm.isEmpty()) {
      return false;
    }
    if (!(value instanceof String text)) {
      return false;
    }
    return text.toLowerCase().contains(normalizedTerm);
  }

  private static QuerySpec parseQuerySpec(String rawSoql) {
    if (rawSoql == null || rawSoql.isBlank()) {
      throw new IllegalArgumentException("SOQL cannot be blank");
    }

    String rawForModifierCheck = rawSoql.trim();
    if (rawForModifierCheck.startsWith("[") && rawForModifierCheck.endsWith("]")) {
      rawForModifierCheck = rawForModifierCheck.substring(1, rawForModifierCheck.length() - 1).trim();
    }
    if (rawForModifierCheck.endsWith(";")) {
      rawForModifierCheck = rawForModifierCheck.substring(0, rawForModifierCheck.length() - 1).trim();
    }
    boolean includeAllRows = TRAILING_ALL_ROWS_PATTERN.matcher(rawForModifierCheck).find();

    String soql = sanitize(rawSoql);
    String masked = maskNestedSoqlClauses(soql);
    Matcher fromMatcher = FROM_PATTERN.matcher(masked);
    if (!fromMatcher.find()) {
      throw new IllegalArgumentException("SOQL must contain FROM <SObject>: " + rawSoql);
    }
    int fromStart = fromMatcher.start();
    String sobjectType = fromMatcher.group(1);
    SelectSpec selectSpec = parseSelectSpec(soql.substring(0, fromStart).trim(), rawSoql, sobjectType);

    Matcher whereKeyword = WHERE_KEYWORD.matcher(masked);
    int whereStart = -1;
    int whereEnd = -1;
    if (whereKeyword.find()) {
      whereStart = whereKeyword.start();
      whereEnd = whereKeyword.end();
    }

    Matcher groupByKeyword = GROUP_BY_KEYWORD.matcher(masked);
    int groupByStart = -1;
    int groupByEnd = -1;
    if (groupByKeyword.find()) {
      groupByStart = groupByKeyword.start();
      groupByEnd = groupByKeyword.end();
    }

    Matcher havingKeyword = HAVING_KEYWORD.matcher(masked);
    int havingStart = -1;
    int havingEnd = -1;
    if (havingKeyword.find()) {
      havingStart = havingKeyword.start();
      havingEnd = havingKeyword.end();
    }

    Matcher orderByKeyword = ORDER_BY_KEYWORD.matcher(masked);
    int orderByStart = -1;
    int orderByEnd = -1;
    if (orderByKeyword.find()) {
      orderByStart = orderByKeyword.start();
      orderByEnd = orderByKeyword.end();
    }

    int limit = 0;
    int limitStart = -1;
    Matcher limitMatcher = LIMIT_PATTERN.matcher(masked);
    if (limitMatcher.find()) {
      limitStart = limitMatcher.start();
      limit = Integer.parseInt(limitMatcher.group(1));
    }

    int offset = 0;
    int offsetStart = -1;
    Matcher offsetMatcher = OFFSET_PATTERN.matcher(masked);
    if (offsetMatcher.find()) {
      offsetStart = offsetMatcher.start();
      offset = Integer.parseInt(offsetMatcher.group(1));
    }

    if (whereStart >= 0 && orderByStart >= 0 && orderByStart < whereStart) {
      throw new IllegalArgumentException("ORDER BY before WHERE is not supported: " + rawSoql);
    }
    if (whereStart >= 0 && groupByStart >= 0 && groupByStart < whereStart) {
      throw new IllegalArgumentException("GROUP BY before WHERE is not supported: " + rawSoql);
    }
    if (havingStart >= 0 && groupByStart < 0) {
      throw new IllegalArgumentException("HAVING requires GROUP BY: " + rawSoql);
    }
    if (groupByStart >= 0 && havingStart >= 0 && havingStart < groupByStart) {
      throw new IllegalArgumentException("HAVING before GROUP BY is not supported: " + rawSoql);
    }
    if (groupByStart >= 0 && orderByStart >= 0 && orderByStart < groupByStart) {
      throw new IllegalArgumentException("ORDER BY before GROUP BY is not supported: " + rawSoql);
    }
    if (havingStart >= 0 && orderByStart >= 0 && orderByStart < havingStart) {
      throw new IllegalArgumentException("ORDER BY before HAVING is not supported: " + rawSoql);
    }
    if (orderByStart >= 0 && limitStart >= 0 && limitStart < orderByStart) {
      throw new IllegalArgumentException("LIMIT before ORDER BY is not supported: " + rawSoql);
    }
    if (orderByStart >= 0 && offsetStart >= 0 && offsetStart < orderByStart) {
      throw new IllegalArgumentException("OFFSET before ORDER BY is not supported: " + rawSoql);
    }
    if (limitStart >= 0 && offsetStart >= 0 && offsetStart < limitStart) {
      throw new IllegalArgumentException("OFFSET before LIMIT is not supported: " + rawSoql);
    }

    WhereExpr whereExpr = null;
    if (whereStart >= 0) {
      int whereBodyEnd =
          nextClauseStart(soql.length(), whereEnd, groupByStart, orderByStart, limitStart, offsetStart);
      String whereExprRaw = soql.substring(whereEnd, whereBodyEnd).trim();
      whereExpr = parseWhereExpression(whereExprRaw, rawSoql);
    }

    List<String> groupByFields = List.of();
    if (groupByStart >= 0) {
      int groupByBodyEnd =
          nextClauseStart(
              soql.length(), groupByEnd, havingStart, orderByStart, limitStart, offsetStart);
      String groupByRaw = soql.substring(groupByEnd, groupByBodyEnd).trim();
      groupByFields = parseGroupByFields(groupByRaw, rawSoql);
    }

    HavingExpr havingExpr = null;
    if (havingStart >= 0) {
      int havingBodyEnd = nextClauseStart(soql.length(), havingEnd, orderByStart, limitStart, offsetStart);
      String havingRaw = soql.substring(havingEnd, havingBodyEnd).trim();
      havingExpr = parseHavingExpression(havingRaw, rawSoql, groupByFields);
    }

    validateSelectSpec(selectSpec, groupByFields, rawSoql);

    List<OrderByKey> orderByKeys = List.of();
    if (orderByStart >= 0) {
      int orderByBodyEnd = nextClauseStart(soql.length(), orderByEnd, limitStart, offsetStart);
      String orderByExpr = soql.substring(orderByEnd, orderByBodyEnd).trim();
      orderByKeys = parseOrderByKeys(orderByExpr, rawSoql);
    }

    return new QuerySpec(
        sobjectType,
        selectSpec,
        whereExpr,
        groupByFields,
        havingExpr,
        orderByKeys,
        limit,
        offset,
        includeAllRows);
  }

  private static SelectSpec parseSelectSpec(String selectExpr, String rawSoql, String fromType) {
    if (selectExpr == null || selectExpr.isBlank()) {
      throw new IllegalArgumentException("SOQL must begin with SELECT: " + rawSoql);
    }
    if (!selectExpr.regionMatches(true, 0, "select", 0, 6)) {
      throw new IllegalArgumentException("SOQL must begin with SELECT: " + rawSoql);
    }

    String body = selectExpr.substring(6).trim();
    if (body.isEmpty()) {
      throw new IllegalArgumentException("SELECT expression cannot be blank: " + rawSoql);
    }

    List<String> terms = splitByComma(body);
    List<SelectItem> items = new ArrayList<>(terms.size());
    boolean hasAggregate = false;
    int aggregateOrdinal = 0;
    for (String term : terms) {
      String normalized = term == null ? "" : term.trim();
      if (normalized.isEmpty()) {
        continue;
      }

      if (isFieldsSelector(normalized)) {
        items.add(SelectItem.fieldsSelector(normalized));
        continue;
      }

      if (normalized.startsWith("(") && normalized.endsWith(")") && isTopLevelWrapped(normalized)) {
        ChildSubquerySpec childSubquery = parseChildSubquerySpec(normalized, rawSoql, fromType);
        items.add(SelectItem.childSubquery(childSubquery, normalized));
        continue;
      }

      Matcher aggregateMatcher = SELECT_AGGREGATE_PATTERN.matcher(normalized);
      if (aggregateMatcher.matches()) {
        AggregateFunction function = parseAggregateFunction(aggregateMatcher.group(1), rawSoql);
        String aggregateArg = aggregateMatcher.group(2);
        String alias = aggregateMatcher.group(3);
        boolean countAll =
            function == AggregateFunction.COUNT
                && (aggregateArg == null
                    || aggregateArg.isBlank()
                    || "*".equals(aggregateArg.trim()));
        String field = null;
        if (!countAll && aggregateArg != null && !aggregateArg.isBlank()) {
          field = aggregateArg.trim();
        }
        if (!countAll && (field == null || field.isBlank())) {
          throw new IllegalArgumentException("aggregate field is required: " + rawSoql);
        }
        String outputName =
            alias != null && !alias.isBlank()
                ? alias.trim()
                : "expr" + aggregateOrdinal;
        items.add(
            SelectItem.aggregate(function, field, countAll, outputName, normalized));
        aggregateOrdinal += 1;
        hasAggregate = true;
        continue;
      }

      Matcher fieldMatcher = SELECT_FIELD_PATTERN.matcher(normalized);
      if (fieldMatcher.matches()) {
        String field = fieldMatcher.group(1).trim();
        String alias = fieldMatcher.group(2);
        String outputName = alias != null && !alias.isBlank() ? alias.trim() : field;
        items.add(SelectItem.field(field, outputName, normalized));
        continue;
      }

      Matcher datePartMatcher = SELECT_DATE_PART_FIELD_PATTERN.matcher(normalized);
      if (datePartMatcher.matches()) {
        String functionName = datePartMatcher.group(1);
        String field = datePartMatcher.group(2).trim();
        String alias = datePartMatcher.group(3);
        String expression = normalizeDatePartExpression(functionName, field);
        String outputName = alias != null && !alias.isBlank() ? alias.trim() : expression;
        items.add(SelectItem.field(expression, outputName, normalized));
        continue;
      }

      throw new IllegalArgumentException("unsupported SELECT term: " + normalized + " in " + rawSoql);
    }

    if (items.isEmpty()) {
      throw new IllegalArgumentException("SELECT expression cannot be blank: " + rawSoql);
    }
    return new SelectSpec(items, hasAggregate);
  }

  private static boolean isFieldsSelector(String selectTerm) {
    if (selectTerm == null) {
      return false;
    }
    String normalized = selectTerm.trim();
    if (!normalized.regionMatches(true, 0, "FIELDS(", 0, 7) || !normalized.endsWith(")")) {
      return false;
    }
    if (normalized.length() <= 8) {
      return false;
    }
    String mode = normalized.substring(7, normalized.length() - 1).trim();
    return mode.equalsIgnoreCase("STANDARD")
        || mode.equalsIgnoreCase("CUSTOM")
        || mode.equalsIgnoreCase("ALL");
  }

  private static ChildSubquerySpec parseChildSubquerySpec(
      String termText, String rawSoql, String parentType) {
    String wrapped = termText == null ? "" : termText.trim();
    if (!(wrapped.startsWith("(") && wrapped.endsWith(")") && isTopLevelWrapped(wrapped))) {
      throw new IllegalArgumentException("child subquery must be wrapped in parentheses: " + rawSoql);
    }

    String inner = wrapped.substring(1, wrapped.length() - 1).trim();
    if (!inner.regionMatches(true, 0, "select", 0, 6)) {
      throw new IllegalArgumentException("unsupported SELECT term: " + termText + " in " + rawSoql);
    }

    QuerySpec rawSpec = parseQuerySpec(inner);
    if (rawSpec.selectSpec == null || rawSpec.selectSpec.items == null || rawSpec.selectSpec.items.isEmpty()) {
      throw new IllegalArgumentException("child subquery SELECT cannot be blank: " + rawSoql);
    }
    for (SelectItem item : rawSpec.selectSpec.items) {
      if (item.kind == SelectItemKind.CHILD_SUBQUERY) {
        throw new IllegalArgumentException("nested child subquery is not supported: " + rawSoql);
      }
    }

    String relationshipName = rawSpec.sobjectType;
    if (relationshipName != null && relationshipName.contains(".")) {
      relationshipName = relationshipName.substring(relationshipName.lastIndexOf('.') + 1);
    }
    String childType = null;
    String parentLinkField = null;
    Schema.ChildRelationship schemaRelationship =
        Schema.resolveChildRelationship(parentType, relationshipName);
    if (schemaRelationship != null) {
      childType = schemaRelationship.childType;
      parentLinkField = schemaRelationship.parentLinkField;
    }
    if (childType == null || childType.isBlank()) {
      childType = inferChildTypeFromRelationship(relationshipName);
    }
    if (childType == null || childType.isBlank()) {
      throw new IllegalArgumentException("cannot infer child object type from relationship: " + relationshipName);
    }
    if (parentLinkField == null || parentLinkField.isBlank()) {
      parentLinkField = inferParentLinkField(parentType);
    }

    QuerySpec normalizedSpec =
        new QuerySpec(
            childType,
            rawSpec.selectSpec,
            rawSpec.whereExpr,
            rawSpec.groupByFields,
            rawSpec.havingExpr,
            rawSpec.orderByKeys,
            rawSpec.limit,
            rawSpec.offset,
            rawSpec.includeAllRows);
    return new ChildSubquerySpec(relationshipName, normalizedSpec, parentLinkField);
  }

  private static String inferChildTypeFromRelationship(String relationshipName) {
    if (relationshipName == null || relationshipName.isBlank()) {
      return null;
    }
    String relation = relationshipName.trim();
    if (relation.length() > 3 && relation.regionMatches(true, relation.length() - 3, "__r", 0, 3)) {
      return relation.substring(0, relation.length() - 3) + "__c";
    }
    if (relation.length() > 3 && relation.regionMatches(true, relation.length() - 3, "ies", 0, 3)) {
      return relation.substring(0, relation.length() - 3) + "y";
    }
    if (relation.length() > 1 && relation.endsWith("s")) {
      return relation.substring(0, relation.length() - 1);
    }
    return relation;
  }

  private static String inferParentLinkField(String parentType) {
    if (parentType == null || parentType.isBlank()) {
      return null;
    }
    String normalized = parentType.trim();
    if (normalized.length() > 3
        && normalized.regionMatches(true, normalized.length() - 3, "__c", 0, 3)) {
      return normalized;
    }
    return normalized + "Id";
  }

  private static List<String> parseGroupByFields(String groupByExpr, String rawSoql) {
    if (groupByExpr == null || groupByExpr.isBlank()) {
      throw new IllegalArgumentException("GROUP BY expression cannot be blank: " + rawSoql);
    }

    List<String> terms = splitByComma(groupByExpr);
    List<String> out = new ArrayList<>(terms.size());
    for (String term : terms) {
      List<String> rollupFields = parseRollupGroupByTerm(term);
      if (rollupFields != null) {
        for (String rollupField : rollupFields) {
          if (!containsIgnoreCase(out, rollupField)) {
            out.add(rollupField);
          }
        }
        continue;
      }
      String normalized = normalizeGroupByFieldTerm(term);
      if (normalized == null) {
        throw new IllegalArgumentException("unsupported GROUP BY field: " + term + " in " + rawSoql);
      }
      if (!containsIgnoreCase(out, normalized)) {
        out.add(normalized);
      }
    }

    if (out.isEmpty()) {
      throw new IllegalArgumentException("GROUP BY expression cannot be blank: " + rawSoql);
    }
    return out;
  }

  private static List<String> parseRollupGroupByTerm(String rawTerm) {
    if (rawTerm == null || rawTerm.isBlank()) {
      return null;
    }
    String normalized = rawTerm.trim();
    if (!normalized.regionMatches(true, 0, "ROLLUP(", 0, 7) || !normalized.endsWith(")")) {
      return null;
    }
    String body = normalized.substring(7, normalized.length() - 1).trim();
    if (body.isEmpty()) {
      return List.of();
    }
    List<String> terms = splitByComma(body);
    List<String> out = new ArrayList<>(terms.size());
    for (String term : terms) {
      String normalizedField = normalizeGroupByFieldTerm(term);
      if (normalizedField == null) {
        return null;
      }
      out.add(normalizedField);
    }
    return out;
  }

  private static String normalizeGroupByFieldTerm(String rawTerm) {
    if (rawTerm == null || rawTerm.isBlank()) {
      return null;
    }
    String normalized = rawTerm.trim();
    if (FIELD_PATH_PATTERN.matcher(normalized).matches()) {
      return normalized;
    }
    DatePartField datePartField = parseDatePartFieldExpression(normalized);
    if (datePartField == null) {
      return null;
    }
    return normalizeDatePartExpression(datePartField.functionName(), datePartField.fieldPath());
  }

  private static String normalizeDatePartExpression(String functionName, String fieldPath) {
    if (functionName == null || functionName.isBlank() || fieldPath == null || fieldPath.isBlank()) {
      return null;
    }
    return functionName.trim().toUpperCase() + "(" + fieldPath.trim() + ")";
  }

  private static DatePartField parseDatePartFieldExpression(String expression) {
    if (expression == null || expression.isBlank()) {
      return null;
    }
    Matcher matcher = DATE_PART_FIELD_PATTERN.matcher(expression.trim());
    if (!matcher.matches()) {
      return null;
    }
    return new DatePartField(matcher.group(1).trim().toUpperCase(), matcher.group(2).trim());
  }

  private static void validateSelectSpec(SelectSpec selectSpec, List<String> groupByFields, String rawSoql) {
    if (selectSpec == null || selectSpec.items == null || selectSpec.items.isEmpty()) {
      throw new IllegalArgumentException("SELECT expression cannot be blank: " + rawSoql);
    }

    List<String> groups = groupByFields == null ? List.of() : groupByFields;
    boolean hasAggregate = selectSpec.hasAggregate;

    for (SelectItem item : selectSpec.items) {
      if (item.kind == SelectItemKind.CHILD_SUBQUERY && (hasAggregate || !groups.isEmpty())) {
        throw new IllegalArgumentException(
            "child subquery cannot be combined with aggregate/GROUP BY query: " + rawSoql);
      }
    }

    if (groups.isEmpty() && hasAggregate) {
      for (SelectItem item : selectSpec.items) {
        if (item.kind == SelectItemKind.FIELD) {
          throw new IllegalArgumentException(
              "non-aggregate field in aggregate query requires GROUP BY: " + item.field);
        }
      }
      return;
    }

    if (groups.isEmpty()) {
      return;
    }

    for (SelectItem item : selectSpec.items) {
      if (item.kind == SelectItemKind.FIELD && !containsIgnoreCase(groups, item.field)) {
        throw new IllegalArgumentException(
            "selected field must appear in GROUP BY: " + item.field + " in " + rawSoql);
      }
      if (item.kind == SelectItemKind.CHILD_SUBQUERY) {
        throw new IllegalArgumentException(
            "child subquery cannot be used with GROUP BY: " + rawSoql);
      }
    }
  }

  private static AggregateFunction parseAggregateFunction(String text, String rawSoql) {
    if (text == null || text.isBlank()) {
      throw new IllegalArgumentException("aggregate function cannot be blank: " + rawSoql);
    }
    String normalized = text.trim().toUpperCase();
    return switch (normalized) {
      case "COUNT_DISTINCT" -> AggregateFunction.COUNT_DISTINCT;
      case "COUNT" -> AggregateFunction.COUNT;
      case "SUM" -> AggregateFunction.SUM;
      case "AVG" -> AggregateFunction.AVG;
      case "MIN" -> AggregateFunction.MIN;
      case "MAX" -> AggregateFunction.MAX;
      default -> throw new IllegalArgumentException("unsupported aggregate function: " + text);
    };
  }

  private static boolean containsIgnoreCase(String haystack, String needle) {
    if (haystack == null || needle == null) return false;
    return haystack.toLowerCase().contains(needle.toLowerCase());
  }

  /** Strip WITH SECURITY_ENFORCED / WITH USER_MODE / WITH SYSTEM_MODE clauses from SOQL. */
  private static String stripWithClauses(String soql) {
    if (soql == null) return soql;
    // Remove WITH SECURITY_ENFORCED, WITH USER_MODE, WITH SYSTEM_MODE (case-insensitive)
    String cleaned = soql.replaceAll("(?i)\\bWITH\\s+(SECURITY_ENFORCED|USER_MODE|SYSTEM_MODE)\\b", "");
    // Strip toLabel() and FORMAT() wrappers in SELECT — replace with just the field name
    cleaned = cleaned.replaceAll("(?i)\\btoLabel\\(([^)]+)\\)", "$1");
    cleaned = cleaned.replaceAll("(?i)\\bFORMAT\\(([^)]+)\\)", "$1");
    // Normalize "IN: var.method()" to "IN :var" (strip method call)
    cleaned = cleaned.replaceAll("(?i)\\bIN:\\s*(\\w+)\\.\\w+\\(\\)", "IN :$1");
    // Normalize "IN :var.method()" similarly
    cleaned = cleaned.replaceAll("(?i)\\bIN\\s+:(\\w+)\\.\\w+\\(\\)", "IN :$1");
    // Normalize "IN: var" (no space before colon) to "IN :var"
    cleaned = cleaned.replaceAll("(?i)\\bIN:\\s+(\\w+)", "IN :$1");
    // Normalize "IN : var" (space around colon) to "IN :var"
    cleaned = cleaned.replaceAll("(?i)\\bIN\\s+:\\s+(\\w+)", "IN :$1");
    return cleaned.trim();
  }

  /** Check that the queried object is accessible in USER_MODE queries. */
  private static void checkReadAccessForQuery(QuerySpec spec) {
    if (spec == null || spec.sobjectType() == null || spec.sobjectType().isBlank()) {
      return;
    }
    String objectType = spec.sobjectType();
    Schema.DescribeSObjectResult describe = new Schema.DescribeSObjectResult(objectType);
    Map<String, Set<String>> inaccessible = new LinkedHashMap<>();
    Set<String> blockedFields = new LinkedHashSet<>();

    if (!describe.isAccessible()) {
      blockedFields.addAll(selectedRootFields(spec));
      if (blockedFields.isEmpty()) {
        blockedFields.add("Name");
      }
      inaccessible.put(describe.getName(), blockedFields);
      QueryException error =
          new QueryException("Implementation restriction: sObject type '" + objectType + "' is not supported");
      error.setInaccessibleFields(inaccessible);
      throw error;
    }

    for (String fieldName : selectedRootFields(spec)) {
      Schema.DescribeFieldResult fieldDescribe = new Schema.SObjectField(objectType, fieldName).getDescribe();
      if (!fieldDescribe.isAccessible()) {
        blockedFields.add(fieldDescribe.getName());
      }
    }
    if (blockedFields.isEmpty()) {
      return;
    }
    inaccessible.put(describe.getName(), blockedFields);
    QueryException error = new QueryException("Query includes inaccessible fields for " + describe.getName());
    error.setInaccessibleFields(inaccessible);
    throw error;
  }

  private static Set<String> selectedRootFields(QuerySpec spec) {
    Set<String> out = new LinkedHashSet<>();
    if (spec == null
        || spec.sobjectType() == null
        || spec.sobjectType().isBlank()
        || spec.selectSpec() == null
        || spec.selectSpec().items() == null) {
      return out;
    }
    String objectType = spec.sobjectType();
    for (SelectItem item : spec.selectSpec().items()) {
      if (item == null || item.kind() != SelectItemKind.FIELD || item.field() == null || item.field().isBlank()) {
        continue;
      }
      String fieldName = item.field();
      DatePartField datePartField = parseDatePartFieldExpression(fieldName);
      if (datePartField != null) {
        fieldName = datePartField.fieldPath();
      }
      int dot = fieldName.indexOf('.');
      if (dot >= 0) {
        fieldName = fieldName.substring(0, dot);
      }
      Schema.DescribeFieldResult fieldDescribe = new Schema.SObjectField(objectType, fieldName).getDescribe();
      String canonicalName = fieldDescribe.getName();
      if (canonicalName == null || canonicalName.isBlank()) {
        canonicalName = fieldName;
      }
      out.add(canonicalName);
    }
    return out;
  }

  private static boolean containsIgnoreCase(List<String> values, String target) {
    if (values == null || values.isEmpty() || target == null) {
      return false;
    }
    for (String value : values) {
      if (value != null && value.equalsIgnoreCase(target)) {
        return true;
      }
    }
    return false;
  }

  private static String applyBindVariables(String soql, Map<String, Object> bindVariables) {
    if (soql == null || soql.isBlank()) {
      throw new IllegalArgumentException("SOQL cannot be blank");
    }

    Map<String, Object> binds = bindVariables == null ? Map.of() : bindVariables;
    StringBuilder out = new StringBuilder(soql.length() + 32);
    boolean inSingle = false;
    boolean inDouble = false;

    for (int i = 0; i < soql.length(); i += 1) {
      char ch = soql.charAt(i);
      if (ch == '\'' && !inDouble) {
        inSingle = !inSingle;
        out.append(ch);
        continue;
      }
      if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
        out.append(ch);
        continue;
      }

      if (!inSingle && !inDouble && ch == ':') {
        int bindStart = i + 1;
        int bindEnd = bindStart;
        while (bindEnd < soql.length() && isBindNameChar(soql.charAt(bindEnd))) {
          bindEnd += 1;
        }

        if (bindEnd == bindStart) {
          out.append(ch);
          continue;
        }

        String bindName = soql.substring(bindStart, bindEnd);
        int bindExpressionEnd = bindEnd;
        // Skip trailing () method invocation (e.g. :UserInfo.getOrganizationId())
        if (bindEnd + 1 < soql.length() && soql.charAt(bindEnd) == '(' && soql.charAt(bindEnd + 1) == ')') {
          bindExpressionEnd = bindEnd + 2;
        }
        Object bindValue;
        if (isTrimBindInvocation(soql, bindEnd, bindName)) {
          bindValue = resolveTrimmedBindValue(binds, bindName, soql);
        } else {
          bindValue = resolveBindValue(binds, bindName, soql);
        }
        boolean wrappedByParentheses = isWrappedByParentheses(soql, i, bindEnd);
        out.append(formatBindLiteral(bindValue, wrappedByParentheses, bindName));
        i = bindExpressionEnd - 1;
        continue;
      }

      out.append(ch);
    }
    return out.toString();
  }

  private static boolean isBindNameChar(char ch) {
    return Character.isLetterOrDigit(ch) || ch == '_' || ch == '.';
  }

  private static Object resolveBindValue(
      Map<String, Object> bindVariables, String bindName, String rawSoql) {
    if (bindVariables.containsKey(bindName)) {
      return bindVariables.get(bindName);
    }
    for (Map.Entry<String, Object> entry : bindVariables.entrySet()) {
      if (entry.getKey() != null && entry.getKey().equalsIgnoreCase(bindName)) {
        return entry.getValue();
      }
    }
    throw new IllegalArgumentException("missing bind variable :" + bindName + " in SOQL: " + rawSoql);
  }

  private static boolean isTrimBindInvocation(String soql, int bindEnd, String bindName) {
    if (soql == null || bindName == null || bindName.isBlank()) {
      return false;
    }
    if (!bindName.toLowerCase().endsWith(".trim")) {
      return false;
    }
    return bindEnd + 1 < soql.length()
        && soql.charAt(bindEnd) == '('
        && soql.charAt(bindEnd + 1) == ')';
  }

  private static Object resolveTrimmedBindValue(
      Map<String, Object> bindVariables, String bindName, String rawSoql) {
    String baseName = bindName.substring(0, bindName.length() - ".trim".length());
    Object value;
    if (containsBindKey(bindVariables, bindName)) {
      value = resolveBindValue(bindVariables, bindName, rawSoql);
    } else {
      value = resolveBindValue(bindVariables, baseName, rawSoql);
    }
    if (value == null) {
      return null;
    }
    if (value instanceof String text) {
      return text.trim();
    }
    return String.valueOf(value).trim();
  }

  private static boolean containsBindKey(Map<String, Object> bindVariables, String bindName) {
    if (bindVariables == null || bindVariables.isEmpty() || bindName == null || bindName.isBlank()) {
      return false;
    }
    if (bindVariables.containsKey(bindName)) {
      return true;
    }
    for (String candidate : bindVariables.keySet()) {
      if (candidate != null && candidate.equalsIgnoreCase(bindName)) {
        return true;
      }
    }
    return false;
  }

  private static boolean isWrappedByParentheses(String source, int placeholderStart, int placeholderEnd) {
    int previous = previousNonWhitespaceIndex(source, placeholderStart - 1);
    int next = nextNonWhitespaceIndex(source, placeholderEnd);
    return previous >= 0
        && next >= 0
        && source.charAt(previous) == '('
        && source.charAt(next) == ')';
  }

  private static int previousNonWhitespaceIndex(String source, int index) {
    for (int i = index; i >= 0; i -= 1) {
      if (!Character.isWhitespace(source.charAt(i))) {
        return i;
      }
    }
    return -1;
  }

  private static int nextNonWhitespaceIndex(String source, int index) {
    for (int i = index; i < source.length(); i += 1) {
      if (!Character.isWhitespace(source.charAt(i))) {
        return i;
      }
    }
    return -1;
  }

  private static String formatBindLiteral(Object bindValue, boolean wrappedByParentheses, String bindName) {
    if (bindValue instanceof Collection<?> collection) {
      return formatBindCollection(collection, wrappedByParentheses, bindName);
    }
    if (bindValue != null && bindValue.getClass().isArray()) {
      List<Object> values = new ArrayList<>();
      int length = java.lang.reflect.Array.getLength(bindValue);
      for (int i = 0; i < length; i += 1) {
        values.add(java.lang.reflect.Array.get(bindValue, i));
      }
      return formatBindCollection(values, wrappedByParentheses, bindName);
    }
    return toSoqlLiteral(bindValue);
  }

  private static String formatBindCollection(
      Collection<?> values, boolean wrappedByParentheses, String bindName) {
    if (values == null) {
      throw new IllegalArgumentException("bind collection cannot be null: :" + bindName);
    }
    if (values.isEmpty()) {
      return wrappedByParentheses ? "" : "()";
    }
    List<String> out = new ArrayList<>(values.size());
    for (Object value : values) {
      if (value instanceof Collection<?> || (value != null && value.getClass().isArray())) {
        throw new IllegalArgumentException("nested bind collections are not supported: :" + bindName);
      }
      out.add(toSoqlLiteral(value));
    }
    String joined = String.join(", ", out);
    return wrappedByParentheses ? joined : "(" + joined + ")";
  }

  private static String toSoqlLiteral(Object value) {
    if (value == null) {
      return "null";
    }
    if (value instanceof String text) {
      return quoteSoqlString(text);
    }
    if (value instanceof Character ch) {
      return quoteSoqlString(String.valueOf(ch));
    }
    if (value instanceof Boolean bool) {
      return bool ? "true" : "false";
    }
    if (value instanceof Number number) {
      double numeric = number.doubleValue();
      if (!Double.isFinite(numeric)) {
        throw new IllegalArgumentException("bind number must be finite: " + number);
      }
      return String.valueOf(number);
    }
    if (value instanceof ApexSObject row) {
      if (row.id() == null || row.id().isBlank()) {
        return "null";
      }
      return quoteSoqlString(row.id());
    }
    if (value instanceof Enum<?> enumValue) {
      return quoteSoqlString(enumValue.name());
    }
    return quoteSoqlString(String.valueOf(value));
  }

  private static String quoteSoqlString(String value) {
    if (value == null) {
      return "null";
    }
    if (value.isEmpty()) {
      return "''";
    }
    String escaped = value.replace("'", "''");
    return "'" + escaped + "'";
  }

  private static String decodeQuotedLiteral(String text, char quote) {
    if (text == null || text.isEmpty()) {
      return "";
    }

    StringBuilder out = new StringBuilder(text.length());
    for (int i = 0; i < text.length(); i += 1) {
      char ch = text.charAt(i);

      // SQL-style escaped quote: '' or "" (depending on delimiter)
      if (ch == quote && i + 1 < text.length() && text.charAt(i + 1) == quote) {
        out.append(quote);
        i += 1;
        continue;
      }

      // Keep compatibility with backslash-escaped quote/backslash.
      if (ch == '\\' && i + 1 < text.length()) {
        char next = text.charAt(i + 1);
        if (next == quote || next == '\\') {
          out.append(next);
          i += 1;
          continue;
        }
      }

      out.append(ch);
    }
    return out.toString();
  }

  private static String sanitize(String soql) {
    String out = soql.trim();
    if (out.startsWith("[") && out.endsWith("]")) {
      out = out.substring(1, out.length() - 1).trim();
    }
    if (out.endsWith(";")) {
      out = out.substring(0, out.length() - 1).trim();
    }
    out = stripTrailingSoqlModifier(out, TRAILING_FOR_UPDATE_PATTERN);
    out = stripTrailingSoqlModifier(out, TRAILING_FOR_VIEW_PATTERN);
    out = stripTrailingSoqlModifier(out, TRAILING_FOR_REFERENCE_PATTERN);
    out = stripTrailingSoqlModifier(out, TRAILING_ALL_ROWS_PATTERN);
    out = stripInlineSoqlModifier(out, INLINE_WITH_MODE_PATTERN);
    return out;
  }

  private static String maskNestedSoqlClauses(String soql) {
    if (soql == null || soql.isEmpty()) {
      return soql;
    }

    StringBuilder out = new StringBuilder(soql.length());
    int parenDepth = 0;
    boolean inSingle = false;
    boolean inDouble = false;

    for (int i = 0; i < soql.length(); i += 1) {
      char ch = soql.charAt(i);
      if (inSingle) {
        if (ch == '\'' && i + 1 < soql.length() && soql.charAt(i + 1) == '\'') {
          out.append(' ');
          out.append(' ');
          i += 1;
          continue;
        }
        if (ch == '\'') {
          inSingle = false;
        }
        out.append(' ');
        continue;
      }
      if (inDouble) {
        if (ch == '"') {
          inDouble = false;
        }
        out.append(' ');
        continue;
      }

      if (ch == '\'') {
        inSingle = true;
        out.append(' ');
        continue;
      }
      if (ch == '"') {
        inDouble = true;
        out.append(' ');
        continue;
      }
      if (ch == '(') {
        parenDepth += 1;
        out.append(' ');
        continue;
      }
      if (ch == ')') {
        if (parenDepth > 0) {
          parenDepth -= 1;
        }
        out.append(' ');
        continue;
      }

      if (parenDepth > 0) {
        out.append(' ');
      } else {
        out.append(ch);
      }
    }
    return out.toString();
  }

  private static String stripTrailingSoqlModifier(String soql, Pattern pattern) {
    if (soql == null || soql.isBlank() || pattern == null) {
      return soql;
    }
    Matcher matcher = pattern.matcher(soql);
    if (!matcher.find()) {
      return soql;
    }
    return soql.substring(0, matcher.start()).trim();
  }

  private static String stripInlineSoqlModifier(String soql, Pattern pattern) {
    if (soql == null || soql.isBlank() || pattern == null) {
      return soql;
    }
    Matcher matcher = pattern.matcher(soql);
    if (!matcher.find()) {
      return soql;
    }
    return matcher.replaceAll(" ");
  }

  private static int nextClauseStart(int defaultEnd, int bodyStart, int... clauseStarts) {
    int end = defaultEnd;
    if (clauseStarts == null || clauseStarts.length == 0) {
      return end;
    }
    for (int clauseStart : clauseStarts) {
      if (clauseStart >= 0 && clauseStart > bodyStart) {
        end = Math.min(end, clauseStart);
      }
    }
    return end;
  }

  private static WhereExpr parseWhereExpression(String whereExpr, String rawSoql) {
    if (whereExpr == null || whereExpr.isBlank()) {
      throw new IllegalArgumentException("WHERE clause cannot be blank: " + rawSoql);
    }
    return parseWhereOrExpression(whereExpr.trim(), rawSoql);
  }

  private static HavingExpr parseHavingExpression(
      String havingExpr, String rawSoql, List<String> groupByFields) {
    if (havingExpr == null || havingExpr.isBlank()) {
      throw new IllegalArgumentException("HAVING clause cannot be blank: " + rawSoql);
    }
    return parseHavingOrExpression(havingExpr.trim(), rawSoql, groupByFields == null ? List.of() : groupByFields);
  }

  private static HavingExpr parseHavingOrExpression(
      String expression, String rawSoql, List<String> groupByFields) {
    List<String> orTerms = splitByLogicalKeyword(expression, "or");
    if (orTerms.size() <= 1) {
      return parseHavingAndExpression(expression, rawSoql, groupByFields);
    }

    List<HavingExpr> out = new ArrayList<>(orTerms.size());
    for (String term : orTerms) {
      out.add(parseHavingAndExpression(term.trim(), rawSoql, groupByFields));
    }
    return new HavingLogicalExpr(LogicalOperator.OR, out);
  }

  private static HavingExpr parseHavingAndExpression(
      String expression, String rawSoql, List<String> groupByFields) {
    List<String> andTerms = splitByLogicalKeyword(expression, "and");
    if (andTerms.size() <= 1) {
      return parseHavingNotExpression(expression, rawSoql, groupByFields);
    }

    List<HavingExpr> out = new ArrayList<>(andTerms.size());
    for (String term : andTerms) {
      out.add(parseHavingNotExpression(term.trim(), rawSoql, groupByFields));
    }
    return new HavingLogicalExpr(LogicalOperator.AND, out);
  }

  private static HavingExpr parseHavingNotExpression(
      String expression, String rawSoql, List<String> groupByFields) {
    String normalized = expression == null ? "" : expression.trim();
    if (normalized.isEmpty()) {
      throw new IllegalArgumentException("HAVING clause cannot be blank: " + rawSoql);
    }

    int notCount = 0;
    while (startsWithLogicalNot(normalized)) {
      notCount += 1;
      normalized = normalized.substring(3).trim();
      if (normalized.isEmpty()) {
        throw new IllegalArgumentException("NOT requires an expression in HAVING: " + rawSoql);
      }
    }

    HavingExpr primary = parseHavingPrimary(normalized, rawSoql, groupByFields);
    if ((notCount & 1) == 0) {
      return primary;
    }
    return new HavingNotExpr(primary);
  }

  private static HavingExpr parseHavingPrimary(
      String expression, String rawSoql, List<String> groupByFields) {
    String normalized = expression == null ? "" : expression.trim();
    if (normalized.isEmpty()) {
      throw new IllegalArgumentException("HAVING clause cannot be blank: " + rawSoql);
    }

    if (normalized.startsWith("(") && normalized.endsWith(")") && isTopLevelWrapped(normalized)) {
      String inner = normalized.substring(1, normalized.length() - 1).trim();
      return parseHavingOrExpression(inner, rawSoql, groupByFields);
    }

    return new HavingPredicateExpr(parseHavingClause(normalized, rawSoql, groupByFields));
  }

  private static HavingClause parseHavingClause(
      String clauseText, String rawSoql, List<String> groupByFields) {
    String normalized = stripWrappingParentheses(clauseText == null ? "" : clauseText.trim());
    Matcher matcher = HAVING_CLAUSE_PATTERN.matcher(normalized);
    if (!matcher.matches()) {
      throw new IllegalArgumentException(
          "HAVING supports (=, !=, >, >=, <, <=) over aggregate/group fields: " + rawSoql);
    }

    String left = matcher.group(1) == null ? "" : matcher.group(1).trim();
    String operator = matcher.group(2);
    Object literal = parseLiteral(matcher.group(3).trim());
    HavingOperand operand = parseHavingOperand(left, rawSoql, groupByFields);
    return new HavingClause(operand, operator, literal);
  }

  private static HavingOperand parseHavingOperand(
      String operandText, String rawSoql, List<String> groupByFields) {
    String normalized = operandText == null ? "" : operandText.trim();
    if (normalized.isEmpty()) {
      throw new IllegalArgumentException("HAVING operand cannot be blank: " + rawSoql);
    }

    Matcher aggregateMatcher = HAVING_AGGREGATE_OPERAND_PATTERN.matcher(normalized);
    if (aggregateMatcher.matches()) {
      AggregateFunction function = parseAggregateFunction(aggregateMatcher.group(1), rawSoql);
      String arg = aggregateMatcher.group(2);
      boolean countAll =
          function == AggregateFunction.COUNT
              && (arg == null || arg.isBlank() || "*".equals(arg.trim()));
      String field = null;
      if (!countAll && arg != null && !arg.isBlank()) {
        field = arg.trim();
      }
      if (!countAll && (field == null || field.isBlank())) {
        throw new IllegalArgumentException("HAVING aggregate field cannot be blank: " + rawSoql);
      }
      return new HavingAggregateOperand(function, field, countAll);
    }

    if (FIELD_PATH_PATTERN.matcher(normalized).matches()) {
      int groupFieldIndex = indexOfIgnoreCase(groupByFields, normalized);
      if (groupFieldIndex < 0) {
        throw new IllegalArgumentException(
            "HAVING field must appear in GROUP BY: " + normalized + " in " + rawSoql);
      }
      return new HavingFieldOperand(normalized, groupFieldIndex);
    }

    throw new IllegalArgumentException("unsupported HAVING operand: " + operandText + " in " + rawSoql);
  }

  private static int indexOfIgnoreCase(List<String> values, String target) {
    if (values == null || values.isEmpty() || target == null) {
      return -1;
    }
    for (int i = 0; i < values.size(); i += 1) {
      String value = values.get(i);
      if (value != null && value.equalsIgnoreCase(target)) {
        return i;
      }
    }
    return -1;
  }

  private static WhereExpr parseWhereOrExpression(String expression, String rawSoql) {
    List<String> orTerms = splitByLogicalKeyword(expression, "or");
    if (orTerms.size() <= 1) {
      return parseWhereAndExpression(expression, rawSoql);
    }

    List<WhereExpr> out = new ArrayList<>(orTerms.size());
    for (String term : orTerms) {
      out.add(parseWhereAndExpression(term.trim(), rawSoql));
    }
    return new WhereLogicalExpr(LogicalOperator.OR, out);
  }

  private static WhereExpr parseWhereAndExpression(String expression, String rawSoql) {
    List<String> andTerms = splitByLogicalKeyword(expression, "and");
    if (andTerms.size() <= 1) {
      return parseWhereNotExpression(expression, rawSoql);
    }

    List<WhereExpr> out = new ArrayList<>(andTerms.size());
    for (String term : andTerms) {
      out.add(parseWhereNotExpression(term.trim(), rawSoql));
    }
    return new WhereLogicalExpr(LogicalOperator.AND, out);
  }

  private static WhereExpr parseWhereNotExpression(String expression, String rawSoql) {
    String normalized = expression == null ? "" : expression.trim();
    if (normalized.isEmpty()) {
      throw new IllegalArgumentException("WHERE clause cannot be blank: " + rawSoql);
    }

    int notCount = 0;
    while (startsWithLogicalNot(normalized)) {
      notCount += 1;
      normalized = normalized.substring(3).trim();
      if (normalized.isEmpty()) {
        throw new IllegalArgumentException("NOT requires an expression: " + rawSoql);
      }
    }

    WhereExpr primary = parseWherePrimary(normalized, rawSoql);
    if ((notCount & 1) == 0) {
      return primary;
    }
    return new WhereNotExpr(primary);
  }

  private static WhereExpr parseWherePrimary(String expression, String rawSoql) {
    String normalized = expression == null ? "" : expression.trim();
    if (normalized.isEmpty()) {
      throw new IllegalArgumentException("WHERE clause cannot be blank: " + rawSoql);
    }

    if (normalized.startsWith("(") && normalized.endsWith(")") && isTopLevelWrapped(normalized)) {
      String inner = normalized.substring(1, normalized.length() - 1).trim();
      return parseWhereOrExpression(inner, rawSoql);
    }

    return new WherePredicateExpr(parseWhereClause(normalized, rawSoql));
  }

  private static WhereClause parseWhereClause(String clauseText, String rawSoql) {
    String normalized = stripWrappingParentheses(clauseText.trim());

    Matcher inMatcher = WHERE_IN_PATTERN.matcher(normalized);
    if (inMatcher.matches()) {
      String field = inMatcher.group(1);
      String operator = inMatcher.group(2).trim().toLowerCase().replaceAll("\\s+", " ");
      String inBody = inMatcher.group(3) == null ? "" : inMatcher.group(3).trim();
      if (looksLikeSelectClause(inBody)) {
        return new WhereClause(field, operator, parseSemiJoinLiteral(inBody, rawSoql));
      }
      List<Object> inValues = parseInLiteralList(inBody, rawSoql);
      return new WhereClause(field, operator, inValues);
    }

    Matcher inBindMatcher = WHERE_IN_BIND_PATTERN.matcher(normalized);
    if (inBindMatcher.matches()) {
      String field = inBindMatcher.group(1);
      String operator = inBindMatcher.group(2).trim().toLowerCase().replaceAll("\\s+", " ");
      // Database.query(String) cannot resolve lexical bind variables;
      // preserve execution by treating unresolved IN binds as an empty set.
      return new WhereClause(field, operator, List.of());
    }

    Matcher likeMatcher = WHERE_LIKE_PATTERN.matcher(normalized);
    if (likeMatcher.matches()) {
      String field = likeMatcher.group(1);
      Object literal = parseLiteral(likeMatcher.group(2).trim());
      return new WhereClause(field, "like", literal);
    }

    Matcher isNullMatcher = WHERE_NULL_PATTERN.matcher(normalized);
    if (isNullMatcher.matches()) {
      String field = isNullMatcher.group(1);
      String negated = isNullMatcher.group(2);
      String operator = negated == null ? "is null" : "is not null";
      return new WhereClause(field, operator, null);
    }

    Matcher whereMatcher = WHERE_PATTERN.matcher(normalized);
    if (whereMatcher.matches()) {
      return new WhereClause(whereMatcher.group(1), whereMatcher.group(2), parseLiteral(whereMatcher.group(3).trim()));
    }

    throw new IllegalArgumentException(
        "only WHERE with AND/OR/NOT and operators (=, !=, >, >=, <, <=, IN, NOT IN, LIKE, IS NULL, IS NOT NULL) is supported: "
            + rawSoql);
  }

  private static boolean looksLikeSelectClause(String text) {
    if (text == null) {
      return false;
    }
    String normalized = text.trim();
    return normalized.length() >= 6 && normalized.regionMatches(true, 0, "select", 0, 6);
  }

  private static SemiJoinLiteral parseSemiJoinLiteral(String subqueryText, String rawSoql) {
    QuerySpec subquery = parseQuerySpec(subqueryText);
    if (subquery.selectSpec == null
        || subquery.selectSpec.items == null
        || subquery.selectSpec.items.size() != 1) {
      throw new IllegalArgumentException("semi-join subquery must select exactly one field: " + rawSoql);
    }
    if (subquery.selectSpec.hasAggregate || (subquery.groupByFields != null && !subquery.groupByFields.isEmpty())) {
      throw new IllegalArgumentException("semi-join subquery cannot use aggregate/GROUP BY: " + rawSoql);
    }

    SelectItem selected = subquery.selectSpec.items.get(0);
    if (selected.kind != SelectItemKind.FIELD || selected.field == null || selected.field.isBlank()) {
      throw new IllegalArgumentException("semi-join subquery must select a plain field: " + rawSoql);
    }

    return new SemiJoinLiteral(subquery, selected.field);
  }

  private static boolean startsWithLogicalNot(String text) {
    if (text == null) {
      return false;
    }
    if (text.length() < 3 || !text.regionMatches(true, 0, "not", 0, 3)) {
      return false;
    }
    if (text.length() == 3) {
      return true;
    }
    char boundary = text.charAt(3);
    return Character.isWhitespace(boundary) || boundary == '(';
  }

  private static String stripWrappingParentheses(String text) {
    String out = text == null ? "" : text.trim();
    while (out.startsWith("(") && out.endsWith(")") && isTopLevelWrapped(out)) {
      out = out.substring(1, out.length() - 1).trim();
    }
    return out;
  }

  private static boolean isTopLevelWrapped(String text) {
    int depth = 0;
    boolean inSingle = false;
    boolean inDouble = false;
    for (int i = 0; i < text.length(); i += 1) {
      char ch = text.charAt(i);
      if (ch == '\'' && !inDouble) {
        inSingle = !inSingle;
        continue;
      }
      if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
        continue;
      }
      if (inSingle || inDouble) {
        continue;
      }
      if (ch == '(') {
        depth += 1;
      } else if (ch == ')') {
        depth -= 1;
        if (depth == 0 && i < text.length() - 1) {
          return false;
        }
      }
      if (depth < 0) {
        return false;
      }
    }
    return depth == 0;
  }

  private static List<String> splitByLogicalKeyword(String expression, String keyword) {
    List<String> out = new ArrayList<>();
    String source = expression.trim();
    if (source.isEmpty()) {
      return out;
    }
    int start = 0;
    boolean inSingle = false;
    boolean inDouble = false;
    int parenDepth = 0;
    int keywordLength = keyword.length();

    for (int i = 0; i < source.length(); i += 1) {
      char ch = source.charAt(i);
      if (ch == '\'' && !inDouble) {
        inSingle = !inSingle;
        continue;
      }
      if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
        continue;
      }
      if (!inSingle && !inDouble) {
        if (ch == '(') {
          parenDepth += 1;
          continue;
        }
        if (ch == ')' && parenDepth > 0) {
          parenDepth -= 1;
          continue;
        }
      }
      if (inSingle || inDouble) {
        continue;
      }
      if (parenDepth != 0) {
        continue;
      }
      if (i + keywordLength <= source.length()
          && source.regionMatches(true, i, keyword, 0, keywordLength)
          && i > 0
          && i + keywordLength < source.length()
          && Character.isWhitespace(source.charAt(i - 1))
          && Character.isWhitespace(source.charAt(i + keywordLength))) {
        out.add(source.substring(start, i).trim());
        start = i + keywordLength;
      }
    }

    out.add(source.substring(start).trim());
    return out;
  }

  private static List<OrderByKey> parseOrderByKeys(String orderByExpr, String rawSoql) {
    if (orderByExpr == null || orderByExpr.isBlank()) {
      throw new IllegalArgumentException("ORDER BY expression cannot be blank: " + rawSoql);
    }

    List<String> terms = splitByComma(orderByExpr);
    List<OrderByKey> keys = new ArrayList<>(terms.size());
    for (String term : terms) {
      Matcher orderByMatcher = ORDER_BY_PATTERN.matcher(term.trim());
      if (!orderByMatcher.matches()) {
        throw new IllegalArgumentException(
            "only ORDER BY <field> [ASC|DESC] [NULLS FIRST|LAST] (comma-separated) is supported: "
                + rawSoql);
      }
      String field = orderByMatcher.group(1);
      String direction = orderByMatcher.group(2);
      String nullDirection = orderByMatcher.group(3);
      boolean descending = direction != null && direction.equalsIgnoreCase("desc");
      Boolean nullsFirst = null;
      if (nullDirection != null) {
        nullsFirst = nullDirection.equalsIgnoreCase("first");
      }
      keys.add(new OrderByKey(field, descending, nullsFirst));
    }
    return keys;
  }

  private static List<String> splitByComma(String raw) {
    List<String> out = new ArrayList<>();
    StringBuilder token = new StringBuilder();
    boolean inSingle = false;
    boolean inDouble = false;
    int parenDepth = 0;
    for (int i = 0; i < raw.length(); i += 1) {
      char ch = raw.charAt(i);
      if (ch == '\'' && !inDouble) {
        inSingle = !inSingle;
        token.append(ch);
        continue;
      }
      if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
        token.append(ch);
        continue;
      }
      if (!inSingle && !inDouble) {
        if (ch == '(') {
          parenDepth += 1;
          token.append(ch);
          continue;
        }
        if (ch == ')' && parenDepth > 0) {
          parenDepth -= 1;
          token.append(ch);
          continue;
        }
        if (ch == ',' && parenDepth == 0) {
          String term = token.toString().trim();
          if (!term.isEmpty()) {
            out.add(term);
          }
          token.setLength(0);
          continue;
        }
      }
      token.append(ch);
    }

    String tail = token.toString().trim();
    if (!tail.isEmpty()) {
      out.add(tail);
    }
    return out;
  }

  private static List<Object> parseInLiteralList(String rawList, String rawSoql) {
    if (rawList == null) {
      throw new IllegalArgumentException("IN list cannot be null: " + rawSoql);
    }

    List<Object> values = new ArrayList<>();
    StringBuilder token = new StringBuilder();
    boolean inSingle = false;
    boolean inDouble = false;
    for (int i = 0; i < rawList.length(); i += 1) {
      char ch = rawList.charAt(i);
      if (ch == '\'' && !inDouble) {
        inSingle = !inSingle;
        token.append(ch);
        continue;
      }
      if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
        token.append(ch);
        continue;
      }
      if (ch == ',' && !inSingle && !inDouble) {
        addInLiteralToken(values, token);
        token.setLength(0);
        continue;
      }
      token.append(ch);
    }
    addInLiteralToken(values, token);
    return values;
  }

  private static void addInLiteralToken(List<Object> values, StringBuilder token) {
    String text = token.toString().trim();
    if (text.isEmpty()) {
      return;
    }
    values.add(parseLiteral(text));
  }

  private static Object parseLiteral(String raw) {
    String value = raw.trim();
    if ((value.startsWith("'") && value.endsWith("'")) || (value.startsWith("\"") && value.endsWith("\""))) {
      return decodeQuotedLiteral(value.substring(1, value.length() - 1), value.charAt(0));
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

    DateRangeLiteral relativeDateLiteral = parseRelativeDateLiteral(value);
    if (relativeDateLiteral != null) {
      return relativeDateLiteral;
    }

    LocalDate absoluteDateLiteral = parseAbsoluteDateLiteral(value);
    if (absoluteDateLiteral != null) {
      return absoluteDateLiteral;
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

  private static DateRangeLiteral parseRelativeDateLiteral(String literal) {
    if (literal == null || literal.isBlank()) {
      return null;
    }

    LocalDate today = LocalDate.now(SOQL_CLOCK);
    if ("TODAY".equalsIgnoreCase(literal)) {
      return DateRangeLiteral.singleDay(today);
    }
    if ("YESTERDAY".equalsIgnoreCase(literal)) {
      return DateRangeLiteral.singleDay(today.minusDays(1));
    }
    if ("TOMORROW".equalsIgnoreCase(literal)) {
      return DateRangeLiteral.singleDay(today.plusDays(1));
    }

    Matcher matcher = RELATIVE_N_DAYS_LITERAL_PATTERN.matcher(literal.trim());
    if (!matcher.matches()) {
      return null;
    }

    int dayCount = Integer.parseInt(matcher.group(2));
    String type = matcher.group(1);
    if ("last_n_days".equalsIgnoreCase(type)) {
      return new DateRangeLiteral(today.minusDays(dayCount), today);
    }
    if ("next_n_days".equalsIgnoreCase(type)) {
      return new DateRangeLiteral(today, today.plusDays(dayCount));
    }
    if ("n_days_ago".equalsIgnoreCase(type)) {
      return DateRangeLiteral.singleDay(today.minusDays(dayCount));
    }

    return null;
  }

  private static LocalDate parseAbsoluteDateLiteral(String literal) {
    if (literal == null || literal.isBlank()) {
      return null;
    }
    String normalized = literal.trim();
    try {
      return LocalDate.parse(normalized, DateTimeFormatter.ISO_LOCAL_DATE);
    } catch (DateTimeParseException ignored) {
      // fallthrough
    }
    return parseIsoDateLike(normalized);
  }

  private static LocalDate toDateValue(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof Date date) {
      return date.value();
    }
    if (value instanceof DateTime dateTime) {
      Date resolvedDate = dateTime.date();
      return resolvedDate == null ? null : resolvedDate.value();
    }
    if (value instanceof LocalDate localDate) {
      return localDate;
    }
    if (value instanceof LocalDateTime localDateTime) {
      return localDateTime.toLocalDate();
    }
    if (value instanceof OffsetDateTime offsetDateTime) {
      return offsetDateTime.toLocalDate();
    }
    if (value instanceof Instant instant) {
      return instant.atOffset(ZoneOffset.UTC).toLocalDate();
    }
    if (value instanceof java.util.Date utilDate) {
      return Instant.ofEpochMilli(utilDate.getTime()).atOffset(ZoneOffset.UTC).toLocalDate();
    }
    if (value instanceof CharSequence text) {
      return parseIsoDateLike(text.toString().trim());
    }
    return null;
  }

  private static LocalDate parseIsoDateLike(String text) {
    if (text == null || text.isBlank()) {
      return null;
    }

    try {
      return LocalDate.parse(text, DateTimeFormatter.ISO_LOCAL_DATE);
    } catch (DateTimeParseException ignored) {
      // fallthrough
    }
    try {
      return OffsetDateTime.parse(text, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toLocalDate();
    } catch (DateTimeParseException ignored) {
      // fallthrough
    }
    try {
      return LocalDateTime.parse(text, DateTimeFormatter.ISO_LOCAL_DATE_TIME).toLocalDate();
    } catch (DateTimeParseException ignored) {
      // fallthrough
    }
    try {
      return Instant.parse(text).atOffset(ZoneOffset.UTC).toLocalDate();
    } catch (DateTimeParseException ignored) {
      // fallthrough
    }
    try {
      return OffsetDateTime.parse(text, DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSZ"))
          .toLocalDate();
    } catch (DateTimeParseException ignored) {
      // fallthrough
    }
    try {
      return OffsetDateTime.parse(text, DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssZ"))
          .toLocalDate();
    } catch (DateTimeParseException ignored) {
      return null;
    }
  }

  private static String toLikeRegex(String pattern) {
    StringBuilder regex = new StringBuilder();
    regex.append("^");
    boolean escaping = false;
    for (int i = 0; i < pattern.length(); i += 1) {
      char ch = pattern.charAt(i);
      if (escaping) {
        appendEscapedRegexChar(regex, ch);
        escaping = false;
      } else if (ch == '\\') {
        escaping = true;
      } else if (ch == '%') {
        regex.append(".*");
      } else if (ch == '_') {
        regex.append(".");
      } else {
        appendEscapedRegexChar(regex, ch);
      }
    }
    if (escaping) {
      appendEscapedRegexChar(regex, '\\');
    }
    regex.append("$");
    return regex.toString();
  }

  private static void appendEscapedRegexChar(StringBuilder regex, char ch) {
    if ("\\.[]{}()*+-?^$|".indexOf(ch) >= 0) {
      regex.append("\\");
    }
    regex.append(ch);
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

  private static void validateForInsert(State state, ApexSObject record) {
    validateCustomInsertConstraints(record);
    validateStandardRequiredFields(record, true);

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
    validateUniqueFields(state, record, definition, null);
  }

  private static void validateCustomInsertConstraints(ApexSObject record) {
    if (record == null || record.type() == null || record.type().isBlank()) {
      return;
    }
    if (isType(record.type(), "Event_Recipes_Demo__e")) {
      if (isBlankValue(record.get("AccountId__c"))) {
        throw new DmlFailure(
            "REQUIRED_FIELD_MISSING",
            "required field missing: AccountId__c",
            new String[] {"AccountId__c"});
      }
      return;
    }
    if (isType(record.type(), "ContentVersion")) {
      Object versionData = record.get("VersionData");
      if (!(versionData instanceof byte[] bytes) || bytes.length == 0) {
        throw new IllegalArgumentException("content version requires non-empty VersionData");
      }
      if (isBlankValue(record.get("Title"))) {
        throw new IllegalArgumentException("content version requires Title");
      }
      if (isBlankValue(record.get("PathOnClient"))) {
        throw new IllegalArgumentException("content version requires PathOnClient");
      }
      return;
    }
    if (isType(record.type(), "ContentDocumentLink")) {
      Object linkedEntityId = record.get("LinkedEntityId");
      String linkedEntityText = linkedEntityId == null ? null : String.valueOf(linkedEntityId).trim();
      if (linkedEntityText == null || linkedEntityText.isEmpty()) {
        throw new IllegalArgumentException("content document link requires LinkedEntityId");
      }
      if (findActiveRowById(linkedEntityText) == null) {
        throw new IllegalArgumentException("invalid LinkedEntityId: " + linkedEntityText);
      }

      Object contentDocumentId = record.get("ContentDocumentId");
      String contentDocumentText =
          contentDocumentId == null ? null : String.valueOf(contentDocumentId).trim();
      if (contentDocumentText == null || contentDocumentText.isEmpty()) {
        throw new IllegalArgumentException("content document link requires ContentDocumentId");
      }
      if (findActiveRowByIdAndType(contentDocumentText, "ContentDocument") == null) {
        throw new IllegalArgumentException("invalid ContentDocumentId: " + contentDocumentText);
      }
    }
  }

  private static void ensureContentVersionDocumentLinkage(
      State state, ApexSObject stored, ApexSObject inputRecord, String contentVersionId) {
    if (state == null || stored == null || contentVersionId == null || contentVersionId.isBlank()) {
      return;
    }

    String contentDocumentId = null;
    Object existingContentDocumentId = stored.get("ContentDocumentId");
    if (existingContentDocumentId != null) {
      String text = String.valueOf(existingContentDocumentId).trim();
      if (!text.isEmpty()) {
        contentDocumentId = text;
      }
    }
    if (contentDocumentId == null) {
      contentDocumentId = nextId(state, "ContentDocument");
      stored.set("ContentDocumentId", contentDocumentId);
      if (inputRecord != null) {
        inputRecord.set("ContentDocumentId", contentDocumentId);
      }
    }
    stored.set("IsLatest", Boolean.TRUE);
    if (inputRecord != null) {
      inputRecord.set("IsLatest", Boolean.TRUE);
    }

    Map<String, ApexSObject> bucket =
        state.active.computeIfAbsent("ContentDocument", ignored -> new LinkedHashMap<>());
    ApexSObject document = bucket.get(contentDocumentId);
    if (document == null) {
      document = ApexSObject.of("ContentDocument").withId(contentDocumentId);
    }
    Object title = stored.get("Title");
    if (!isBlankValue(title)) {
      document.set("Title", title);
    }
    String fileType = inferFileType(stored.get("PathOnClient"));
    if (fileType != null) {
      document.set("FileType", fileType);
    }
    document.set("LatestPublishedVersionId", contentVersionId);
    bucket.put(contentDocumentId, document);

    ensureFirstPublishLocationLink(state, stored, inputRecord, contentDocumentId);
  }

  private static void ensureFirstPublishLocationLink(
      State state, ApexSObject stored, ApexSObject inputRecord, String contentDocumentId) {
    if (state == null || contentDocumentId == null || contentDocumentId.isBlank()) {
      return;
    }
    String linkedEntityId = normalizeIdValue(stored == null ? null : stored.get("FirstPublishLocationId"));
    if (linkedEntityId == null && inputRecord != null) {
      linkedEntityId = normalizeIdValue(inputRecord.get("FirstPublishLocationId"));
    }
    if (linkedEntityId == null) {
      return;
    }
    if (findActiveRowById(linkedEntityId) == null) {
      return;
    }

    Map<String, ApexSObject> links =
        state.active.computeIfAbsent("ContentDocumentLink", ignored -> new LinkedHashMap<>());
    for (ApexSObject existing : links.values()) {
      if (existing == null) {
        continue;
      }
      if (compareEquality(existing.get("ContentDocumentId"), contentDocumentId)
          && compareEquality(existing.get("LinkedEntityId"), linkedEntityId)) {
        return;
      }
    }

    String linkId = nextId(state, "ContentDocumentLink");
    ApexSObject link =
        ApexSObject.of("ContentDocumentLink")
            .withId(linkId)
            .set("ContentDocumentId", contentDocumentId)
            .set("LinkedEntityId", linkedEntityId)
            .set("ShareType", "V")
            .set("Visibility", "AllUsers");
    links.put(linkId, link);
  }

  private static void ensureContentDistributionFields(
      ApexSObject stored, ApexSObject inputRecord, String contentDistributionId) {
    if (stored == null) {
      return;
    }
    String versionId = normalizeIdValue(stored.get("ContentVersionId"));
    if (versionId == null && inputRecord != null) {
      versionId = normalizeIdValue(inputRecord.get("ContentVersionId"));
    }
    String existingDownloadUrl = trimToNull(stored.get("ContentDownloadUrl"));
    if (existingDownloadUrl != null) {
      return;
    }
    String token = versionId == null ? contentDistributionId : versionId;
    if (token == null || token.isBlank()) {
      token = "content";
    }
    String downloadUrl = "https://example.invalid/sfc/servlet.shepherd/version/download/" + token;
    stored.set("ContentDownloadUrl", downloadUrl);
    if (inputRecord != null) {
      inputRecord.set("ContentDownloadUrl", downloadUrl);
    }
  }

  private static void ensureEmailMessageToRelations(
      State state, ApexSObject stored, ApexSObject inputRecord, String emailMessageId) {
    if (state == null || emailMessageId == null || emailMessageId.isBlank()) {
      return;
    }
    List<String> toIds = normalizeIdList(stored == null ? null : stored.get("toIds"));
    if (toIds.isEmpty() && inputRecord != null) {
      toIds = normalizeIdList(inputRecord.get("toIds"));
    }
    if (toIds.isEmpty()) {
      return;
    }

    Map<String, ApexSObject> relations =
        state.active.computeIfAbsent("EmailMessageRelation", ignored -> new LinkedHashMap<>());
    for (String relationId : toIds) {
      if (relationId == null || relationId.isBlank()) {
        continue;
      }
      boolean exists = false;
      for (ApexSObject existing : relations.values()) {
        if (existing == null) {
          continue;
        }
        if (compareEquality(existing.get("EmailMessageId"), emailMessageId)
            && compareEquality(existing.get("RelationId"), relationId)) {
          exists = true;
          break;
        }
      }
      if (exists) {
        continue;
      }

      ApexSObject target = findActiveRowById(relationId);
      String relationAddress = target == null ? null : trimToNull(target.get("Email"));
      String relationRowId = nextId(state, "EmailMessageRelation");
      ApexSObject relation =
          ApexSObject.of("EmailMessageRelation")
              .withId(relationRowId)
              .set("EmailMessageId", emailMessageId)
              .set("RelationId", relationId)
              .set("RelationType", "ToAddress");
      if (relationAddress != null) {
        relation.set("RelationAddress", relationAddress);
      }
      relations.put(relationRowId, relation);
    }
  }

  private static List<String> normalizeIdList(Object value) {
    if (value == null) {
      return List.of();
    }
    List<String> out = new ArrayList<>();
    if (value instanceof Collection<?> collection) {
      for (Object item : collection) {
        String normalized = normalizeIdValue(item);
        if (normalized != null) {
          out.add(normalized);
        }
      }
      return out;
    }
    if (value.getClass().isArray()) {
      int length = java.lang.reflect.Array.getLength(value);
      for (int i = 0; i < length; i += 1) {
        String normalized = normalizeIdValue(java.lang.reflect.Array.get(value, i));
        if (normalized != null) {
          out.add(normalized);
        }
      }
      return out;
    }
    String normalized = normalizeIdValue(value);
    return normalized == null ? List.of() : List.of(normalized);
  }

  private static String normalizeIdValue(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof ApexSObject row) {
      return normalizeId(row.id());
    }
    return normalizeId(String.valueOf(value));
  }

  private static void applySystemTimestampsOnInsert(ApexSObject stored, ApexSObject inputRecord) {
    if (stored == null) {
      return;
    }
    DateTime now = DateTime.now();
    if (!stored.hasField("CreatedDate") || stored.get("CreatedDate") == null) {
      stored.set("CreatedDate", now);
      if (inputRecord != null) {
        inputRecord.set("CreatedDate", now);
      }
    }
    if (!stored.hasField("LastModifiedDate") || stored.get("LastModifiedDate") == null) {
      stored.set("LastModifiedDate", now);
      if (inputRecord != null) {
        inputRecord.set("LastModifiedDate", now);
      }
    }
  }

  private static void applySystemTimestampsOnUpdate(ApexSObject stored, ApexSObject inputRecord) {
    if (stored == null) {
      return;
    }
    DateTime now = DateTime.now();
    stored.set("LastModifiedDate", now);
    if (inputRecord != null) {
      inputRecord.set("LastModifiedDate", now);
    }
  }

  private static void validateForUpdate(State state, ApexSObject record) {
    validateStandardRequiredFields(record, false);
    Schema.ObjectDefinition definition = Schema.find(record.type());
    if (definition == null) {
      return;
    }
    validateDefinedFields(record, definition);
    validateUniqueFields(state, record, definition, normalizeId(record.id()));
  }

  private static void validateDefinedFields(ApexSObject record, Schema.ObjectDefinition definition) {
    for (Map.Entry<String, Object> entry : record.fields().entrySet()) {
      Schema.FieldDefinition field = definition.field(entry.getKey());
      if (field == null) {
        // In emulation mode, unknown fields are allowed (schema is partial).
        continue;
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

      validateFieldConstraints(field, value);
    }
  }

  private static void validateStandardRequiredFields(ApexSObject record, boolean isInsert) {
    if (record == null || record.type() == null || record.type().isBlank()) {
      return;
    }
    if (isType(record.type(), "Account")) {
      boolean missingOrBlankName = isBlankValue(record.get("Name"));
      if (isInsert && missingOrBlankName) {
        throw new DmlFailure(
            "REQUIRED_FIELD_MISSING", "required field missing: Name", new String[] {"Name"});
      }
      if (!isInsert && record.hasField("Name") && missingOrBlankName) {
        throw new DmlFailure(
            "FIELD_CUSTOM_VALIDATION_EXCEPTION",
            "Script-thrown exception",
            new String[] {"Name"});
      }
    }
  }

  private static void validateFieldConstraints(Schema.FieldDefinition field, Object value) {
    if (field.maxLength != null && value instanceof CharSequence text && text.length() > field.maxLength.intValue()) {
      throw new DmlFailure(
          "STRING_TOO_LONG",
          "value too long for field " + field.name + ": max length " + field.maxLength,
          new String[] {field.name});
    }

    if (!field.picklistValues.isEmpty()) {
      if (!(value instanceof String text) || !field.picklistValues.contains(text)) {
        throw new DmlFailure(
            "INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST",
            "invalid picklist value for field " + field.name + ": " + value,
            new String[] {field.name});
      }
    }

    if (field.precision != null || field.scale != null) {
      validateNumericPrecisionScale(field, value);
    }

    if (field.referenceType != null && !field.referenceType.isBlank()) {
      validateReferenceConstraint(field, value);
    }
  }

  private static void validateNumericPrecisionScale(Schema.FieldDefinition field, Object value) {
    BigDecimal decimal = toBigDecimal(value);
    if (decimal == null) {
      return;
    }

    int precision = field.precision == null ? Integer.MAX_VALUE : field.precision.intValue();
    int scale = field.scale == null ? 0 : field.scale.intValue();

    BigDecimal normalized = decimal.stripTrailingZeros();
    if (normalized.scale() < 0) {
      normalized = normalized.setScale(0);
    }

    int actualPrecision = normalized.precision();
    int actualScale = Math.max(0, normalized.scale());
    int allowedWholeDigits = Math.max(0, precision - scale);
    int actualWholeDigits = Math.max(0, actualPrecision - actualScale);

    if (actualPrecision > precision || actualScale > scale || actualWholeDigits > allowedWholeDigits) {
      throw new DmlFailure(
          "NUMBER_OUTSIDE_VALID_RANGE",
          "value exceeds precision/scale for field "
              + field.name
              + ": precision="
              + precision
              + " scale="
              + scale
              + " value="
              + value,
          new String[] {field.name});
    }
  }

  private static void validateReferenceConstraint(Schema.FieldDefinition field, Object value) {
    if (!(value instanceof String referenceId) || referenceId.isBlank()) {
      return;
    }
    ApexSObject related = findActiveRowByIdAndType(referenceId, field.referenceType);
    if (related == null) {
      throw new DmlFailure(
          "FIELD_INTEGRITY_EXCEPTION",
          "invalid reference for field " + field.name + ": " + referenceId,
          new String[] {field.name});
    }
  }

  private static void validateUniqueFields(
      State state, ApexSObject record, Schema.ObjectDefinition definition, String selfId) {
    if (state == null || record == null || definition == null) {
      return;
    }
    for (Schema.FieldDefinition field : definition.fields.values()) {
      if (field == null || (!field.unique && !field.externalId)) {
        continue;
      }

      Object value = record.get(field.name);
      if (value == null) {
        continue;
      }
      List<ApexSObject> conflicts = findRowsByFieldValue(state, record.type(), field.name, value, selfId);
      if (conflicts.isEmpty()) {
        continue;
      }

      throw new DmlFailure(
          "DUPLICATE_VALUE",
          "duplicate value for field " + field.name + ": " + value,
          new String[] {field.name});
    }
  }

  private static List<ApexSObject> findRowsByFieldValue(
      State state, String type, String fieldName, Object value, String excludeId) {
    if (state == null || type == null || type.isBlank() || fieldName == null || fieldName.isBlank()) {
      return List.of();
    }
    Map<String, ApexSObject> bucket = state.active.get(type);
    if (bucket == null || bucket.isEmpty()) {
      return List.of();
    }

    List<ApexSObject> matches = new ArrayList<>();
    for (Map.Entry<String, ApexSObject> entry : bucket.entrySet()) {
      String rowId = normalizeId(entry.getKey());
      if (excludeId != null && rowId != null && rowId.equalsIgnoreCase(excludeId)) {
        continue;
      }

      ApexSObject row = entry.getValue();
      if (row == null) {
        continue;
      }
      if (excludeId != null && row.id() != null && row.id().equalsIgnoreCase(excludeId)) {
        continue;
      }

      Object rowValue = row.get(fieldName);
      if (compareEquality(rowValue, value)) {
        matches.add(row);
      }
    }
    return matches;
  }

  private static BigDecimal toBigDecimal(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof BigDecimal decimal) {
      return decimal;
    }
    if (value instanceof Integer intValue) {
      return BigDecimal.valueOf(intValue.longValue());
    }
    if (value instanceof Long longValue) {
      return BigDecimal.valueOf(longValue);
    }
    if (value instanceof Number number) {
      return new BigDecimal(String.valueOf(number));
    }
    return null;
  }

  private static boolean isTypeCompatible(Schema.FieldType expected, Object value) {
    return switch (expected) {
      case STRING -> value instanceof String;
      case BOOLEAN -> value instanceof Boolean;
      case INTEGER -> value instanceof Integer;
      case LONG -> value instanceof Long || value instanceof Integer;
      case DECIMAL, DOUBLE -> value instanceof Number;
      case DATE -> value instanceof String || value instanceof java.time.LocalDate
          || value instanceof java.time.LocalDateTime || value instanceof Date || value instanceof DateTime;
      case DATETIME -> value instanceof String || value instanceof java.time.LocalDate
          || value instanceof java.time.LocalDateTime || value instanceof Date || value instanceof DateTime;
      case ID -> value instanceof String text && !text.isBlank();
    };
  }

  private static String requireId(ApexSObject record, String operation) {
    String id = normalizeId(record.id());
    if (id == null) {
      throw new apexemu.runtime.System.DmlException(
          "Id not specified in an update call: " + record.type());
    }
    return id;
  }

  private static boolean hasIdCollision(State state, String type, String id) {
    Map<String, ApexSObject> activeBucket = findBucketByType(state.active, type);
    if (activeBucket != null && activeBucket.containsKey(id)) {
      return true;
    }
    Map<String, ApexSObject> deletedBucket = findBucketByType(state.deleted, type);
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

  private static Map<String, ApexSObject> findBucketByType(
      Map<String, Map<String, ApexSObject>> buckets, String type) {
    if (buckets == null || buckets.isEmpty() || type == null || type.isBlank()) {
      return null;
    }
    Map<String, ApexSObject> direct = buckets.get(type);
    if (direct != null) {
      return direct;
    }
    for (Map.Entry<String, Map<String, ApexSObject>> entry : buckets.entrySet()) {
      if (entry.getKey() != null && entry.getKey().equalsIgnoreCase(type)) {
        return entry.getValue();
      }
    }
    return null;
  }

  private static boolean isType(String actualType, String expectedType) {
    if (actualType == null || expectedType == null) {
      return false;
    }
    return actualType.equalsIgnoreCase(expectedType);
  }

  private static boolean isBlankValue(Object value) {
    if (value == null) {
      return true;
    }
    if (value instanceof String text) {
      return text.isBlank();
    }
    return false;
  }

  private static String inferFileType(Object pathOnClient) {
    if (!(pathOnClient instanceof String path) || path.isBlank()) {
      return null;
    }
    String normalized = path.trim().toLowerCase();
    int dot = normalized.lastIndexOf('.');
    if (dot < 0 || dot == normalized.length() - 1) {
      return null;
    }
    String ext = normalized.substring(dot + 1);
    if (ext.equals("jpg") || ext.equals("jpeg")) {
      return "JPG";
    }
    if (ext.equals("png")) {
      return "PNG";
    }
    if (ext.equals("gif")) {
      return "GIF";
    }
    if (ext.equals("docx")) {
      return "WORD_X";
    }
    if (ext.equals("xlsx")) {
      return "EXCEL_X";
    }
    if (ext.equals("pptx")) {
      return "POWER_POINT_X";
    }
    if (ext.equals("pdf")) {
      return "PDF";
    }
    return ext.toUpperCase();
  }

  private static Database.SaveResult success(String id) {
    return new Database.SaveResult(true, id, new Database.Error[0]);
  }

  private static Database.SaveResult success(String id, boolean created) {
    return new Database.SaveResult(true, id, new Database.Error[0], created);
  }

  private static Database.SaveResult failure(String id, FailureInfo info, String messagePrefix) {
    String message = info.message;
    if (messagePrefix != null && !messagePrefix.isBlank()) {
      message = messagePrefix + ": " + message;
    }
    return new Database.SaveResult(
        false, id, new Database.Error[] {new Database.Error(info.statusCode, message, info.fields)});
  }

  private static Database.MergeResult mergeSuccess(
      String id, List<String> mergedRecordIds, String[] updatedRelatedIds) {
    String[] mergedIds = mergedRecordIds == null ? new String[0] : mergedRecordIds.toArray(new String[0]);
    return new Database.MergeResult(true, id, new Database.Error[0], mergedIds, updatedRelatedIds);
  }

  private static Database.MergeResult mergeFailure(String id, FailureInfo info, String messagePrefix) {
    String message = info.message;
    if (messagePrefix != null && !messagePrefix.isBlank()) {
      message = messagePrefix + ": " + message;
    }
    return new Database.MergeResult(
        false,
        id,
        new Database.Error[] {new Database.Error(info.statusCode, message, info.fields)},
        new String[0],
        new String[0]);
  }

  private static FailureInfo classifyFailure(Throwable error) {
    if (error instanceof DmlFailure dmlFailure) {
      return new FailureInfo(dmlFailure.statusCode, dmlFailure.getMessage(), dmlFailure.fields);
    }
    String message = messageOrDefault(error);
    if (message.contains("requires id") || message.contains("Id not specified in an update call")) {
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

  private static RelatedReparentPlan planRelatedReparent(
      State state, String masterType, String masterId, List<String> duplicateIds) {
    if (state == null || masterId == null || duplicateIds == null || duplicateIds.isEmpty()) {
      return RelatedReparentPlan.empty();
    }

    List<ApexSObject> oldRows = new ArrayList<>();
    List<ApexSObject> newRows = new ArrayList<>();
    for (Map.Entry<String, Map<String, ApexSObject>> bucket : state.active.entrySet()) {
      String rowType = bucket.getKey();
      for (ApexSObject row : bucket.getValue().values()) {
        if (row == null || row.id() == null) {
          continue;
        }
        if (rowType != null && rowType.equalsIgnoreCase(masterType) && row.id().equalsIgnoreCase(masterId)) {
          continue;
        }

        ApexSObject oldSnapshot = row.copy();
        ApexSObject updateCandidate = row.copy();
        if (replaceDuplicateReferences(updateCandidate, rowType, duplicateIds, masterId)) {
          oldRows.add(oldSnapshot);
          newRows.add(updateCandidate);
        }
      }
    }
    return new RelatedReparentPlan(oldRows, newRows);
  }

  private static boolean replaceDuplicateReferences(
      ApexSObject row, String rowType, List<String> duplicateIds, String masterId) {
    boolean changed = false;
    for (Map.Entry<String, Object> field : new ArrayList<>(row.fields().entrySet())) {
      if (!isReferenceField(rowType, field.getKey())) {
        continue;
      }
      if (!(field.getValue() instanceof String textValue)) {
        continue;
      }
      if (!containsIdIgnoreCase(duplicateIds, textValue)) {
        continue;
      }
      if (textValue.equalsIgnoreCase(masterId)) {
        continue;
      }
      row.set(field.getKey(), masterId);
      changed = true;
    }
    return changed;
  }

  private static List<ApexSObject> applyRelatedReparent(State state, RelatedReparentPlan plan) {
    if (plan == null || plan.newRows.isEmpty()) {
      return List.of();
    }

    dispatchBefore(state, DmlVerb.UPDATE, plan.newRows, plan.oldRows);
    for (ApexSObject row : plan.newRows) {
      updateOne(state, row);
    }
    List<ApexSObject> afterRows = snapshotActiveRows(state, plan.newRows, "merge");
    dispatchAfter(DmlVerb.UPDATE, afterRows, plan.oldRows);
    return afterRows;
  }

  private static String[] collectSortedIds(List<ApexSObject> rows) {
    if (rows == null || rows.isEmpty()) {
      return new String[0];
    }
    List<String> ids = new ArrayList<>(rows.size());
    for (ApexSObject row : rows) {
      if (row == null || row.id() == null) {
        continue;
      }
      if (!containsIdIgnoreCase(ids, row.id())) {
        ids.add(row.id());
      }
    }
    ids.sort(String.CASE_INSENSITIVE_ORDER);
    return ids.toArray(new String[0]);
  }

  private static boolean isReferenceField(String sobjectType, String fieldName) {
    if (fieldName == null || fieldName.isBlank()) {
      return false;
    }
    if ("id".equalsIgnoreCase(fieldName)) {
      return false;
    }

    Schema.ObjectDefinition definition = Schema.find(sobjectType);
    if (definition != null) {
      Schema.FieldDefinition schemaField = definition.field(fieldName);
      if (schemaField != null) {
        return schemaField.type == Schema.FieldType.ID;
      }
    }

    String normalized = fieldName.trim().toLowerCase();
    return normalized.endsWith("id") || normalized.endsWith("__c");
  }

  private static boolean containsIdIgnoreCase(List<String> ids, String target) {
    if (ids == null || ids.isEmpty() || target == null) {
      return false;
    }
    for (String id : ids) {
      if (id != null && id.equalsIgnoreCase(target)) {
        return true;
      }
    }
    return false;
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
    String prefix = idPrefixForType(type);
    return prefix + String.format("%012d", state.idSequence) + "AAA";
  }

  private static String idPrefixForType(String type) {
    return Schema.keyPrefixForTypeName(type);
  }

  private interface DmlOperation {
    String apply(State state, ApexSObject record);
  }

  private enum DmlVerb {
    INSERT("insert"),
    UPDATE("update"),
    UPSERT("upsert"),
    DELETE("delete"),
    UNDELETE("undelete");

    final String operationName;

    DmlVerb(String operationName) {
      this.operationName = operationName;
    }
  }

  private enum UpsertPath {
    INSERT,
    UPDATE
  }

  private static final class UpsertPlanRow {
    final int index;
    final ApexSObject record;
    final UpsertPath path;
    final ApexSObject oldSnapshot;

    UpsertPlanRow(int index, ApexSObject record, UpsertPath path, ApexSObject oldSnapshot) {
      this.index = index;
      this.record = record;
      this.path = path;
      this.oldSnapshot = oldSnapshot;
    }
  }

  private static final class MergePlan {
    final List<ApexSObject> duplicateDeleteRows;
    final List<ApexSObject> duplicateOldRows;
    final List<String> duplicateMergedIds;

    MergePlan(
        List<ApexSObject> duplicateDeleteRows,
        List<ApexSObject> duplicateOldRows,
        List<String> duplicateMergedIds) {
      this.duplicateDeleteRows = duplicateDeleteRows;
      this.duplicateOldRows = duplicateOldRows;
      this.duplicateMergedIds = duplicateMergedIds;
    }
  }

  private static final class RelatedReparentPlan {
    final List<ApexSObject> oldRows;
    final List<ApexSObject> newRows;

    RelatedReparentPlan(List<ApexSObject> oldRows, List<ApexSObject> newRows) {
      this.oldRows = oldRows;
      this.newRows = newRows;
    }

    static RelatedReparentPlan empty() {
      return new RelatedReparentPlan(List.of(), List.of());
    }
  }

  private record FailureInfo(String statusCode, String message, String[] fields) {}

  private interface WhereExpr {}

  private enum LogicalOperator {
    AND,
    OR
  }

  private record WherePredicateExpr(WhereClause clause) implements WhereExpr {}

  private record WhereNotExpr(WhereExpr inner) implements WhereExpr {}

  private record WhereLogicalExpr(LogicalOperator operator, List<WhereExpr> terms) implements WhereExpr {}

  private record WhereClause(String field, String operator, Object literal) {}

  private interface HavingExpr {}

  private record HavingPredicateExpr(HavingClause clause) implements HavingExpr {}

  private record HavingNotExpr(HavingExpr inner) implements HavingExpr {}

  private record HavingLogicalExpr(LogicalOperator operator, List<HavingExpr> terms) implements HavingExpr {}

  private record HavingClause(HavingOperand operand, String operator, Object literal) {}

  private interface HavingOperand {}

  private record HavingFieldOperand(String field, int groupFieldIndex) implements HavingOperand {}

  private record HavingAggregateOperand(
      AggregateFunction function, String field, boolean countAll) implements HavingOperand {}

  private enum SelectItemKind {
    FIELD,
    FIELDS_SELECTOR,
    AGGREGATE,
    CHILD_SUBQUERY
  }

  private enum AggregateFunction {
    COUNT_DISTINCT,
    COUNT,
    SUM,
    AVG,
    MIN,
    MAX
  }

  private record SelectItem(
      SelectItemKind kind,
      String field,
      AggregateFunction aggregateFunction,
      boolean countAll,
      String outputName,
      String sourceText,
      ChildSubquerySpec childSubquery) {
    static SelectItem field(String field, String outputName, String sourceText) {
      return new SelectItem(SelectItemKind.FIELD, field, null, false, outputName, sourceText, null);
    }

    static SelectItem fieldsSelector(String sourceText) {
      return new SelectItem(
          SelectItemKind.FIELDS_SELECTOR, null, null, false, "FIELDS", sourceText, null);
    }

    static SelectItem aggregate(
        AggregateFunction function,
        String field,
        boolean countAll,
        String outputName,
        String sourceText) {
      return new SelectItem(
          SelectItemKind.AGGREGATE, field, function, countAll, outputName, sourceText, null);
    }

    static SelectItem childSubquery(ChildSubquerySpec childSubquery, String sourceText) {
      String outputName =
          childSubquery == null || childSubquery.relationName == null
              ? "records"
              : childSubquery.relationName;
      return new SelectItem(
          SelectItemKind.CHILD_SUBQUERY, null, null, false, outputName, sourceText, childSubquery);
    }
  }

  private record SelectSpec(List<SelectItem> items, boolean hasAggregate) {}

  private record GroupKey(List<Object> values) {
    GroupKey {
      values = values == null ? List.of() : List.copyOf(values);
    }
  }

  private record OrderByKey(String field, boolean descending, Boolean nullsFirst) {}

  private record QuerySpec(
      String sobjectType,
      SelectSpec selectSpec,
      WhereExpr whereExpr,
      List<String> groupByFields,
      HavingExpr havingExpr,
      List<OrderByKey> orderByKeys,
      int limit,
      int offset,
      boolean includeAllRows) {}

  private record SoslSpec(String term, boolean nameFieldsOnly, List<String> returningTypes) {
    SoslSpec {
      returningTypes = returningTypes == null ? List.of() : List.copyOf(returningTypes);
    }
  }

  private record ChildSubquerySpec(String relationName, QuerySpec querySpec, String parentLinkField) {}

  private record SemiJoinLiteral(QuerySpec querySpec, String selectedField) {}

  private record DateRangeLiteral(LocalDate startInclusive, LocalDate endInclusive) {
    DateRangeLiteral {
      if (startInclusive == null || endInclusive == null) {
        throw new IllegalArgumentException("date range bounds cannot be null");
      }
      if (endInclusive.isBefore(startInclusive)) {
        throw new IllegalArgumentException("date range end cannot be before start");
      }
    }

    static DateRangeLiteral singleDay(LocalDate day) {
      if (day == null) {
        throw new IllegalArgumentException("date literal day cannot be null");
      }
      return new DateRangeLiteral(day, day);
    }

    boolean contains(LocalDate day) {
      if (day == null) {
        return false;
      }
      return !day.isBefore(startInclusive) && !day.isAfter(endInclusive);
    }
  }

  private record DatePartField(String functionName, String fieldPath) {}

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
    final Map<SemiJoinLiteral, List<Object>> semiJoinCache = new IdentityHashMap<>();
    final List<SavepointSnapshot> savepoints = new ArrayList<>();
    long idSequence;
    long savepointSequence;

    long nextSavepointToken() {
      savepointSequence += 1L;
      return savepointSequence;
    }
  }

  private static final class RuntimeConfig {
    Database.NullOrderDefault nullOrderDefault = Database.NullOrderDefault.FIRST;
  }
}
