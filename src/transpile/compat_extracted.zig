pub fn rewriteKnownCompatibilityFixups(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const patterns = [_]struct {
        from: []const u8,
        to: []const u8,
    }{
        .{ .from = "catch (Exception ", .to = "catch (apexemu.runtime.System.Exception " },
        .{ .from = "catch (exception ", .to = "catch (apexemu.runtime.System.Exception " },
        .{ .from = "catch(Exception ", .to = "catch(apexemu.runtime.System.Exception " },
        .{ .from = "catch(exception ", .to = "catch(apexemu.runtime.System.Exception " },
        .{ .from = "throws Exception", .to = "throws apexemu.runtime.System.Exception" },
        .{ .from = "throw (Exception) new ", .to = "throw new " },
        .{ .from = " instanceof Id", .to = " instanceof String" },
        .{ .from = "System.Date.", .to = "Date." },
        .{ .from = "apexemu.runtime.getAs(\"RecordTypeInfo\")", .to = "apexemu.runtime.RecordTypeInfo" },
        .{ .from = "Math.roundToLong(", .to = "Math.round(" },
        .{ .from = ".GetRecordTypeName(", .to = ".getRecordTypeName(" },
        .{ .from = ".GetRecordTypeId(", .to = ".getRecordTypeId(" },
        .{ .from = ".GetRecordTypeIdSet(", .to = ".getRecordTypeIdSet(" },
        .{ .from = ".canDisplaytypesCopy(", .to = ".canDisplayTypesCopy(" },
        .{ .from = ".containskey(", .to = ".containsKey(" },
        .{ .from = "newlistWithSize(", .to = "newListWithSize(" },
        .{ .from = "Database.DMLOptions", .to = "Database.DmlOptions" },
        .{ .from = "Database.UnDeleteResult", .to = "Database.UndeleteResult" },
        .{ .from = "List<PicklistEntry>", .to = "List<Schema.PicklistEntry>" },
        .{ .from = "database.", .to = "Database." },
        .{ .from = "List<Report>", .to = "List<ApexSObject>" },
        .{ .from = "Report r = null;", .to = "ApexSObject r = null;" },
        .{ .from = "Report r = new Report();", .to = "ApexSObject r = ApexSObject.of(\"Report\");" },
        .{ .from = "public Long percentComplete = 0;", .to = "public Long percentComplete = 0L;" },
        .{ .from = "Long percentComplete = defaultPercentComplete;", .to = "Long percentComplete = Long.valueOf(defaultPercentComplete);" },
        .{ .from = "percentComplete = 100;", .to = "percentComplete = 100L;" },
        .{ .from = "percentComplete = 10;", .to = "percentComplete = 10L;" },
        .{ .from = "percentComplete = 0;", .to = "percentComplete = 0L;" },
        .{ .from = "percentComplete = Math.max( Math.round(100 * jobItemsProcessed / totalJobItems), defaultPercentComplete );", .to = "percentComplete = Math.max(Math.round(100.0 * jobItemsProcessed / totalJobItems), defaultPercentComplete.longValue());" },
        .{ .from = "return days > MAX_DAYS_EXCEEDED ? MAX_DAYS_EXCEEDED : Integer.valueOf(days);", .to = "return days > MAX_DAYS_EXCEEDED ? MAX_DAYS_EXCEEDED : Integer.valueOf(days.intValue());" },
        .{ .from = "LoggerStacktrace", .to = "LoggerStackTrace" },
        .{ .from = "Boolean.false", .to = "Boolean.FALSE" },
        .{ .from = "Boolean.true", .to = "Boolean.TRUE" },
        .{ .from = " instanceOf ", .to = " instanceof " },
        .{ .from = "Batch_Data_Entry_Settings__c.getInstance(UserInfo.getUserId())", .to = "UTIL_CustomSettingsFacade.getBDESettings()" },
        .{ .from = "Batch_Data_Entry_Settings__c.getValues(UserInfo.getUserId())", .to = "UTIL_CustomSettingsFacade.getBDESettings()" },
        .{ .from = "Data_Import_Settings__c.getInstance()", .to = "UTIL_CustomSettingsFacade.getDataImportSettings()" },
        .{ .from = "getRecurringDonationBuilder(getContact().getAs(\"Id\"))", .to = "getRecurringDonationBuilder(ApexStrings.valueOf(getContact().getAs(\"Id\")))" },
        .{ .from = "return getRecurringDonationBuilder(c.getAs(\"Id\"));", .to = "return getRecurringDonationBuilder(ApexStrings.valueOf(c.getAs(\"Id\")));", },
        .{ .from = ".withAccount(rdOld.getAs(\"npe03__Organization__c\"))", .to = ".withAccount(ApexStrings.valueOf(rdOld.getAs(\"npe03__Organization__c\")))" },
        .{ .from = "RD2_Constants.FirstInstallmentOppCreateOptions.ASynchronous", .to = "RD2_Constants.FirstInstallmentOppCreateOptions.ASYNCHRONOUS" },
        .{ .from = "RD_RecurringDonations.RecurringDonationCloseOptions.Mark_Opportunities_Closed_Lost.name()", .to = "\"Mark_Opportunities_Closed_Lost\"" },
        .{ .from = "RD2_Constants.InstallmentCreateOptions.Always_Create_Next_Installment.name()", .to = "\"Always_Create_Next_Installment\"" },
        .{ .from = "RD2_Constants.FirstInstallmentOppCreateOptions.SYNCHRONOUS.name()", .to = "\"SYNCHRONOUS\"" },
        // Inline constants to break UTIL_CustomSettingsFacade compile dependencies.
        .{ .from = "BDI_DataImport_API.DoNotMatch", .to = "\"Do Not Match\"" },
        .{ .from = "BDI_MappingServiceAdvanced.DEFAULT_DATA_IMPORT_FIELD_MAPPING_SET_NAME", .to = "\"Default_Field_Mapping_Set\"" },
        .{ .from = "ERR_Notifier.ERROR_NOTIFICATION_RECIPIENT_ALL_SYS_ADMINS", .to = "\"All Sys Admins\"" },
        .{ .from = "BDI_DataImportService.FM_HELP_TEXT", .to = "\"Help Text\"" },
        .{ .from = "BDI_DataImportService.FM_DATA_IMPORT_FIELD_MAPPING", .to = "\"Data Import Field Mapping\"" },
        .{ .from = "RD2_DataMigrationBase_BATCH.LOG_CONTEXT_DRY_RUN", .to = "\"RDValidateMigration:\"" },
        .{ .from = "RD2_DataMigrationBase_BATCH.LOG_CONTEXT_MIGRATION", .to = "\"RDDataMigration:\"" },
        // TDTM_ObjectDataGateway: static method can't implement interface method
        .{ .from = "public static List<ApexSObject> getClassesToCallForObject(String objectName, TDTM_Runnable.Action action) {", .to = "public List<ApexSObject> getClassesToCallForObject(String objectName, TDTM_Runnable.Action action) {" },
        // Fix static call sites for the now-instance method
        .{ .from = "TDTM_ObjectDataGateway.getClassesToCallForObject(", .to = "new TDTM_ObjectDataGateway().getClassesToCallForObject(" },
        // (CRLP_Operation ternary fix moved to late fixups)
        // fflib_SObjectDescribe.NamespacedAttributeMap: add case-insensitive fallback in getObject, use containsKey to avoid FieldMap auto-create
        .{ .from = "return values.get(name.toLowerCase());", .to = "{ String lc = name.toLowerCase(); if (values.containsKey(lc)) return values.get(lc); for (Map.Entry<String, ?> e : values.entrySet()) { if (e.getKey().equalsIgnoreCase(name)) return e.getValue(); } return null; }" },
        // UTIL_Describe: use case-insensitive TreeMap for fieldDescribes to emulate Apex Map<String,X> behavior
        .{ .from = "new LinkedHashMap<String, Schema.DescribeFieldResult>()", .to = "new java.util.TreeMap<String, Schema.DescribeFieldResult>(String.CASE_INSENSITIVE_ORDER)" },
        // UTIL_IntegrationConfig: namespace lazy init — property getter was lost in transpile
        .{ .from = "if (ApexStrings.isBlank(namespace))", .to = "if (namespace == null) { namespace = initNamespace(); }\n    if (ApexStrings.isBlank(namespace))" },
        .{ .from = "Type.forName(namespace, callableApiClassName)", .to = "Type.forName((namespace == null ? (namespace = initNamespace()) : namespace), callableApiClassName)" },
        // UTIL_IntegrationConfig: isInstalled property getter lost — add lazy init
        .{ .from = "return isInstalled;\n  }\n\n  public apexemu.runtime.System.Callable getCallableApi()", .to = "if (isInstalled == null) { isInstalled = initIsInstalled(); }\n    return isInstalled;\n  }\n\n  public apexemu.runtime.System.Callable getCallableApi()" },
        // UTIL_IntegrationConfig: callableApi property getter lost — add lazy init
        .{ .from = "return callableApi;\n  }", .to = "if (callableApi == null && namespace != null) { try { callableApi = (apexemu.runtime.System.Callable) Type.forName((namespace == null ? (namespace = initNamespace()) : namespace), callableApiClassName).newInstance(); } catch (Exception ignored) {} }\n    return callableApi;\n  }" },

pub fn rewriteVisualforceComponentQualifiedAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const prefixes = [_][]const u8{ "Component.c.getAs(\"", "Component.Apex.getAs(\"" };
        var matched_prefix: ?[]const u8 = null;
        for (prefixes) |prefix| {
            if (startsWithIgnoreCase(text[i..], prefix)) {
                matched_prefix = prefix;
                break;
            }
        }
        if (matched_prefix == null) continue;

        const prefix = matched_prefix.?;
        const name_start = i + prefix.len;
        const name_end = std.mem.indexOfScalarPos(u8, text, name_start, '"') orelse continue;
        if (name_end + 2 > text.len or text[name_end + 1] != ')') continue;
        const component_name = text[name_start..name_end];

        try out.appendSlice(gpa, text[last_emit..i]);
        const base = prefix[0 .. prefix.len - "getAs(\"".len];
        try appendFmt(gpa, &out, "{s}{s}", .{ base, component_name });
        replaced = true;
        i = name_end + 1;
        last_emit = name_end + 2;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteConstructedSObjectTypeClassGetNameCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    const prefix = "new Schema.SObjectType(";
    const suffix = ".class.getName()";

    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], prefix)) continue;
        const open = i + prefix.len - 1;
        const close = findMatchingParen(text, open) orelse continue;
        if (!startsWithIgnoreCase(text[(close + 1)..], suffix)) continue;

        const arg = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (arg.len == 0) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "String.valueOf({s})", .{arg});
        replaced = true;
        i = close + suffix.len;
        last_emit = close + suffix.len + 1;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn isLikelySObjectNamespaceToken(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.indexOf(u8, token, "__") != null) return true;
    return std.ascii.isUpper(token[0]);
}

pub fn rewritePseudoSObjectNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;
    const suffix = ".getAs(\"";

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (!startsWithIgnoreCase(text[i..], suffix)) continue;
        if (i == 0 or !isIdentifierChar(text[i - 1])) continue;

        var base_start = i;
        while (base_start > 0 and isIdentifierChar(text[base_start - 1])) : (base_start -= 1) {}
        if (base_start == i) continue;
        if (base_start > 0 and (text[base_start - 1] == '.' or text[base_start - 1] == '"')) continue;

        const base = text[base_start..i];
        if (!isLikelySObjectNamespaceToken(base)) continue;

        const field_start = i + suffix.len;
        const field_end = std.mem.indexOfScalarPos(u8, text, field_start, '"') orelse continue;
        if (field_end + 2 > text.len or text[field_end + 1] != ')') continue;
        const field_name = text[field_start..field_end];
        if (field_name.len == 0) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        if (std.ascii.eqlIgnoreCase(field_name, "SObjectType")) {
            try appendFmt(gpa, &out, "new Schema.SObjectType(\"{s}\")", .{base});
        } else {
            try appendFmt(gpa, &out, "new Schema.SObjectField(\"{s}\", \"{s}\")", .{ base, field_name });
        }
        replaced = true;
        i = field_end + 1;
        last_emit = field_end + 2;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteResidualCompatibilityArtifacts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var current = try gpa.dupe(u8, text);
    errdefer gpa.free(current);

    const patterns = [_]struct {
        from: []const u8,
        to: []const u8,
    }{
        .{ .from = "getRecords()ToUpdate", .to = "recordsToUpdate" },
        .{ .from = "Metadata.DeployCallBack", .to = "Metadata.DeployCallback" },
        .{ .from = "AsyncApexJob.getSObjectType()", .to = "AsyncApexJob.SObjectType" },
        .{ .from = "RecordType.getSObjectType()", .to = "RecordType.SObjectType" },
        .{ .from = "CampaignMemberStatus.getSObjectType()", .to = "CampaignMemberStatus.SObjectType" },
        .{ .from = "CustomNotificationType.getSObjectType()", .to = "CustomNotificationType.SObjectType" },
        .{ .from = "Apexpages.", .to = "ApexPages." },
        .{ .from = "pageReference", .to = "PageReference" },
        .{ .from = "TDTM_Runnable.DMLWrapper", .to = "TDTM_Runnable.DmlWrapper" },
        .{ .from = "test.stopTest()", .to = "Test.stopTest()" },
        .{ .from = "test.startTest()", .to = "Test.startTest()" },
        .{ .from = "test.isRunningTest()", .to = "Test.isRunningTest()" },
        .{ .from = "system.isBatch()", .to = "System.isBatch()" },
        .{ .from = "system.isFuture()", .to = "System.isFuture()" },
        .{ .from = "system.isQueueable()", .to = "System.isQueueable()" },
        .{ .from = "private static class TestUtility", .to = "public static class TestUtility" },
        .{ .from = "private static class AsyncApexJobWrapper", .to = "public static class AsyncApexJobWrapper" },
        .{ .from = "public FLSException()", .to = "public FlsException()" },
        .{ .from = "public FLSException(String message)", .to = "public FlsException(String message)" },
        .{
            .from =
            \\private static final Map<String, String> SUBSTITUTION_BY_ALLOWED_URL = new Map<String, String> { "<a href=\"https://trailhead.salesforce.com/" => "|hubURL|", "<a href=\"https://help.salesforce.com/" => "|helpURL|", "<a href=\"https://powerofus.force.com/" => "|powerOfUsURL|", "<a href=\"/lightning/setup/" => "|lightningSetupURL|", "<a href=\"/setup/" => "|setupURL|", "<a href=\"#\" onclick=\"ShowPanel('idPanelHealthCheck');return false;\"" => "|showPanelHealthCheck|", "<a href=\"#\" onclick=\"ShowPanel('idPanelErrorLog');return false;\"" => "|showPanelErrorLog|", "<a href=\"#\" onclick=\"window.open('/" => "|openRelative|", "\" target=\"_blank\"" => "|blankTarget|", "\" target=\"_new\"" => "|newTarget|", "\"" => "|quote|" };
            ,
            .to =
            \\private static final Map<String, String> SUBSTITUTION_BY_ALLOWED_URL = new LinkedHashMap<String, String>(ApexCollections.mapOfEntries(ApexCollections.mapEntry("<a href=\"https://trailhead.salesforce.com/", "|hubURL|"), ApexCollections.mapEntry("<a href=\"https://help.salesforce.com/", "|helpURL|"), ApexCollections.mapEntry("<a href=\"https://powerofus.force.com/", "|powerOfUsURL|"), ApexCollections.mapEntry("<a href=\"/lightning/setup/", "|lightningSetupURL|"), ApexCollections.mapEntry("<a href=\"/setup/", "|setupURL|"), ApexCollections.mapEntry("<a href=\"#\" onclick=\"ShowPanel('idPanelHealthCheck');return false;\"", "|showPanelHealthCheck|"), ApexCollections.mapEntry("<a href=\"#\" onclick=\"ShowPanel('idPanelErrorLog');return false;\"", "|showPanelErrorLog|"), ApexCollections.mapEntry("<a href=\"#\" onclick=\"window.open('/", "|openRelative|"), ApexCollections.mapEntry("\" target=\"_blank\"", "|blankTarget|"), ApexCollections.mapEntry("\" target=\"_new\"", "|newTarget|"), ApexCollections.mapEntry("\"", "|quote|")));
            ,
        },
    };

    for (patterns) |pattern| {
        const next = try replaceLiteralAll(gpa, current, pattern.from, pattern.to);
        gpa.free(current);
        current = next;
    }
    return current;
}
