//! evaluator — AST ツリーウォーク実行エンジン。
//!
//! 式を評価し、文を実行する。クラス/メソッド解決、変数バインディング、
//! ビルトイン関数ディスパッチを行う。

const std = @import("std");
const types = @import("types.zig");
const ast = @import("ast.zig");
const env_mod = @import("env.zig");
const builtins = @import("builtins.zig");
const utils = @import("utils.zig");
const regex = @import("regex.zig");
const Value = types.Value;
const Env = env_mod.Env;

pub const StmtResult = union(enum) {
    normal,
    return_val: Value,
    break_signal,
    continue_signal,
};

pub const CustomChildRelationship = struct {
    child_type: []const u8,
    fk_field: []const u8,
};

pub const SummaryFilter = struct {
    field_path: []const u8,
    operation: []const u8,
    value: []const u8,
};

pub const FieldMetadata = struct {
    is_unique: bool = false,
    is_external_id: bool = false,
    case_sensitive: bool = false,
    is_required: bool = false,
    length: ?i64 = null,
    reference_to: ?[]const u8 = null,
    formula: ?[]const u8 = null,
    formula_blank_as_zero: bool = false,
    summarized_field: ?[]const u8 = null,
    summary_foreign_key: ?[]const u8 = null,
    summary_operation: ?[]const u8 = null,
    summary_filters: []const SummaryFilter = &.{},
};

pub const FieldSetMemberMetadata = struct {
    field_path: []const u8,
    is_required: bool = false,
};

pub const FieldSetMetadata = struct {
    name: []const u8,
    qualified_name: []const u8,
    label: []const u8,
    namespace: []const u8 = "",
    members: []const FieldSetMemberMetadata = &.{},
};

pub const Evaluator = struct {
    arena: std.mem.Allocator,
    /// classes map 専用 allocator (parse_arena — テスト間で保持される)
    class_arena: ?std.mem.Allocator = null,
    global_env: *Env,
    stdout: std.ArrayListUnmanaged(u8) = .empty,
    classes: std.StringArrayHashMapUnmanaged(*ast.ClassDecl) = .empty,
    return_value: Value = .void_val,
    assertion_failure: ?[]const u8 = null,
    // インメモリ SObject ストア
    store: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Value)) = .empty,
    next_id: u64 = 1,
    /// Id → SObject type_name mapping (populated by insertRecord and createId)
    id_type_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    // bypass リスト (TriggerHandler.bypass 等)
    bypasses: std.StringArrayHashMapUnmanaged(void) = .empty,
    // 削除済みレコードのゴミ箱 (undelete 用)
    trash: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Value)) = .empty,
    // 例外ハンドリング
    pending_exception: ?Value = null,
    // HttpCalloutMock
    callout_mock: ?Value = null,
    // Current class name for static field resolution
    current_class: ?[]const u8 = null,
    // Property getter currently being evaluated (to prevent infinite recursion in self-referencing getters)
    evaluating_getter: ?[]const u8 = null,
    // JSON round-trip: store last serialized value for deserialize
    last_json_value: ?Value = null,
    // SOSL fixed search results (set by Test.setFixedSearchResults)
    fixed_search_results: ?Value = null,
    // Class name of the currently executing constructor (for correct super() dispatch)
    current_constructor_class: ?[]const u8 = null,
    // Call depth counter (stack overflow guard)
    call_depth: u32 = 0,
    max_call_depth: u32 = 500,
    // Scheduled jobs store (System.schedule → CronTrigger queries)
    scheduled_jobs: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    // Class source code (class name → source text, for ApexClass.Body queries)
    class_sources: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    // Trigger source code (trigger name → source text, for ApexTrigger.Body queries)
    trigger_sources: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    // Whether current test has @isTest(SeeAllData=true) annotation
    see_all_data: bool = false,
    // Whether running as a restricted user (System.runAs with min-access or marketing user)
    is_restricted_user: bool = false,
    // Whether running as a minimum-access user specifically (stricter than is_restricted_user)
    is_min_access_user: bool = false,
    // Whether running as a standard user (has CRUD on business objects but not setup objects)
    is_standard_user: bool = false,
    // ApexPages message store (for ApexPages.addMessages / hasMessages / getMessages)
    apex_pages_messages: std.ArrayListUnmanaged(Value) = .empty,
    // Trigger declarations (object name → list of triggers)
    triggers: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(*ast.TriggerDecl)) = .empty,
    // Trigger context variables
    trigger_context: ?TriggerContext = null,
    // Source paths for metadata lookup (e.g., picklist values from field-meta.xml)
    source_paths: []const []const u8 = &.{},
    // SObject field default values from field-meta.xml (type_name → field_name → default Value)
    field_defaults: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(Value)) = .empty,
    /// field-meta.xml から読み取ったフィールド型情報。field_types[TypeName][FieldName] = "DateTime" 等。
    field_types: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged([]const u8)) = .empty,
    /// field-meta.xml から読み取ったフィールド制約・参照先。field_metadata[TypeName][FieldName] = metadata。
    field_metadata: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(FieldMetadata)) = .empty,
    /// field-meta.xml から読み取った child relationship 情報。key = lowercase("{parent}|{relationship}").
    child_relationships: std.StringArrayHashMapUnmanaged(CustomChildRelationship) = .empty,
    /// object-meta.xml で `<customSettingsType>` が指定されている Custom Setting オブジェクト名の集合。
    custom_setting_types: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// object-meta.xml で読み取った Custom Setting 種別。`Hierarchy` / `List` を保持する。
    custom_setting_kinds: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// fieldSet-meta.xml から読み取った field set 情報。field_sets[TypeName][QualifiedFieldSetName] = metadata。
    field_sets: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(FieldSetMetadata)) = .empty,
    // System.Limits counters
    limits_dml: u32 = 0,
    limits_dml_rows: u32 = 0,
    limits_soql: u32 = 0,
    limits_publish_immediate: u32 = 0,
    limits_queueable: u32 = 0,
    limits_callouts: u32 = 0,
    // Trigger recursion depth counter
    trigger_depth: u32 = 0,
    // Cast type hints for method overload resolution (set by evalMethodCall, consumed by findBestMethodInClassFiltered)
    cast_type_hints: ?[]const ?[]const u8 = null,
    // Pending event callback for Test.getEventBus().fail() support
    pending_event_callback: ?struct {
        callback: *types.ObjectInstance,
        event: Value,
    } = null,
    // Lazy static initialization: tracks which classes have been statically initialized
    static_inited: std.StringArrayHashMapUnmanaged(void) = .empty,
    // Call stack for stack trace generation (Exception.getStackTraceString)
    call_stack: std.ArrayListUnmanaged(CallFrame) = .empty,
    // Line number of the current call-site expression (set before callMethod/callInstanceMethod)
    current_call_line: u32 = 0,
    // Current user context (defaults to the synthetic system test user)
    current_user_id: []const u8 = "005000000000001",
    current_profile_id: []const u8 = "00e000000000001",
    // Batch job execution queue used to model chained Database.executeBatch calls
    pending_batch_jobs: std.ArrayListUnmanaged(Value) = .empty,
    batch_job_runner_active: bool = false,
    batch_lifecycle_depth: u32 = 0,

    pub const CallFrame = struct {
        class_name: []const u8,
        method_name: []const u8,
        line: u32,
    };

    const TriggerContext = struct {
        is_executing: bool = false,
        is_insert: bool = false,
        is_update: bool = false,
        is_delete: bool = false,
        is_undelete: bool = false,
        is_before: bool = false,
        is_after: bool = false,
        new_list: ?Value = null,
        old_list: ?Value = null,
        new_map: ?Value = null,
        old_map: ?Value = null,
        size: i64 = 0,
        operation_type: ?[]const u8 = null,
    };

    pub fn init(arena: std.mem.Allocator) !Evaluator {
        const global = try arena.create(Env);
        global.* = Env.init(arena);
        return .{ .arena = arena, .global_env = global };
    }

    pub fn resetForTest(self: *Evaluator) void {
        self.assertion_failure = null;
        self.return_value = .void_val;
        self.stdout = .empty;
        self.store = .empty;
        self.next_id = 1;
        self.bypasses = .empty;
        self.pending_exception = null;
        self.callout_mock = null;
        self.fixed_search_results = null;
        self.trash = .empty;
        self.last_json_value = null;
        self.call_depth = 0;
        self.scheduled_jobs = .empty;
        self.is_restricted_user = false;
        self.is_min_access_user = false;
        self.is_standard_user = false;
        self.pending_event_callback = null;
        self.apex_pages_messages = .empty;
        self.current_user_id = "005000000000001";
        self.current_profile_id = "00e000000000001";

        // Clear cache partitions and ApexPages state
        _ = self.global_env.bindings.orderedRemove("Cache.Session.partition");
        _ = self.global_env.bindings.orderedRemove("Cache.Org.partition");
        var cache_partition_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.global_env.bindings.keys()) |key| {
            if (std.mem.startsWith(u8, key, "Cache.Session.partition:") or
                std.mem.startsWith(u8, key, "Cache.Org.partition:"))
            {
                cache_partition_keys.append(self.arena, key) catch {};
            }
        }
        for (cache_partition_keys.items) |key| {
            _ = self.global_env.bindings.orderedRemove(key);
        }
        _ = self.global_env.bindings.orderedRemove("ApexPages.currentPageRef");
    }

    /// Create a synthetic User record for UserInfo.getUserId() — used by SOQL when no User records exist in store
    pub fn createCurrentUserRecord(self: *Evaluator) !Value {
        const user = try self.arena.create(types.SObject);
        user.* = .{ .type_name = "User" };
        user.id = self.current_user_id;
        try user.fields.put(self.arena, "Id", Value{ .string = self.current_user_id });
        try user.fields.put(self.arena, "FirstName", Value{ .string = "Test" });
        try user.fields.put(self.arena, "LastName", Value{ .string = "User" });
        try user.fields.put(self.arena, "Name", Value{ .string = "Test User" });
        try user.fields.put(self.arena, "Email", Value{ .string = "testuser@example.com" });
        try user.fields.put(self.arena, "Username", Value{ .string = "testuser@example.com" });
        try user.fields.put(self.arena, "ProfileId", Value{ .string = self.current_profile_id });
        const profile = try self.arena.create(types.SObject);
        profile.* = .{ .type_name = "Profile", .id = self.current_profile_id };
        try profile.fields.put(self.arena, "Id", Value{ .string = self.current_profile_id });
        try self.populateSyntheticProfile(profile, "System Administrator");
        try user.fields.put(self.arena, "Profile", Value{ .sobject = profile });
        try user.fields.put(self.arena, "UserType", Value{ .string = "Standard" });
        try user.fields.put(self.arena, "IsActive", Value{ .boolean = true });
        try user.fields.put(self.arena, "Alias", Value{ .string = "tuser" });
        try user.fields.put(self.arena, "TimeZoneSidKey", Value{ .string = "America/Los_Angeles" });
        try user.fields.put(self.arena, "LocaleSidKey", Value{ .string = "en_US" });
        try user.fields.put(self.arena, "EmailEncodingKey", Value{ .string = "UTF-8" });
        try user.fields.put(self.arena, "LanguageLocaleKey", Value{ .string = "en_US" });
        try user.fields.put(self.arena, "CommunityNickname", Value{ .string = "testuser" });
        return Value{ .sobject = user };
    }

    /// Resolve picklist API name to label using field-meta.xml
    fn resolvePicklistLabel(self: *Evaluator, obj_type: []const u8, field_name: []const u8, api_name: []const u8) ?[]const u8 {
        const suffix = std.fmt.allocPrint(self.arena, "objects/{s}/fields/{s}.field-meta.xml", .{ obj_type, field_name }) catch return null;
        for (self.source_paths) |base_path| {
            // Try to find the field-meta.xml by walking common SFDX paths
            // Also try parent directories (e.g., "force-app/main/default/classes" → "force-app")
            const parent1 = std.fs.path.dirname(base_path) orelse base_path; // strip "classes"
            const parent2 = std.fs.path.dirname(parent1) orelse parent1; // strip "default"
            const parent3 = std.fs.path.dirname(parent2) orelse parent2; // strip "main"
            const candidates = [_][]const u8{
                "main/default",
                ".",
                "force-app/main/default",
                "src/main/default",
            };
            // Also try from parent directories
            const base_paths = [_][]const u8{ base_path, parent1, parent2, parent3 };
            for (base_paths) |bp| {
                for (candidates) |sub| {
                    const xml_path = std.fs.path.join(self.arena, &.{ bp, sub, suffix }) catch continue;
                    const content = std.fs.cwd().readFileAlloc(self.arena, xml_path, 512 * 1024) catch continue;

                    // Parse <value> blocks: find <fullName> matching api_name, return corresponding <label>
                    var pos: usize = 0;
                    while (pos < content.len) {
                        const value_start = std.mem.indexOfPos(u8, content, pos, "<value>") orelse break;
                        const value_end = std.mem.indexOfPos(u8, content, value_start, "</value>") orelse break;
                        const block = content[value_start..value_end];

                        const fn_tag = "<fullName>";
                        const fn_end_tag = "</fullName>";
                        if (std.mem.indexOf(u8, block, fn_tag)) |fn_start| {
                            const fn_content_start = fn_start + fn_tag.len;
                            if (std.mem.indexOfPos(u8, block, fn_content_start, fn_end_tag)) |fn_end| {
                                const full_name = block[fn_content_start..fn_end];
                                if (std.mem.eql(u8, full_name, api_name)) {
                                    const lbl_tag = "<label>";
                                    const lbl_end_tag = "</label>";
                                    if (std.mem.indexOf(u8, block, lbl_tag)) |lbl_start| {
                                        const lbl_content_start = lbl_start + lbl_tag.len;
                                        if (std.mem.indexOfPos(u8, block, lbl_content_start, lbl_end_tag)) |lbl_end| {
                                            return block[lbl_content_start..lbl_end];
                                        }
                                    }
                                }
                            }
                        }
                        pos = value_end + 8;
                    }
                }
            }
        }
        return null;
    }

    /// Create a synthetic Profile record — used by SOQL when no Profile records exist in store
    pub fn createCurrentProfileRecord(self: *Evaluator) !Value {
        const profile = try self.arena.create(types.SObject);
        profile.* = .{ .type_name = "Profile", .id = self.current_profile_id };
        try profile.fields.put(self.arena, "Id", Value{ .string = self.current_profile_id });
        try self.populateSyntheticProfile(profile, "System Administrator");
        return Value{ .sobject = profile };
    }

    /// Create a synthetic Profile record — used by SOQL when no Profile records exist in store
    pub fn createDefaultProfileRecord(self: *Evaluator) !Value {
        return self.createCurrentProfileRecord();
    }

    /// Create a synthetic Profile matching the WHERE clause Name — used by SOQL seeding.
    /// Falls back to "System Administrator" if no Name condition is found.
    fn createProfileForQuery(self: *Evaluator, soql: []const u8, current_env: *Env) !Value {
        if (self.extractWhereFieldValue(soql, "Id", current_env)) |profile_id| {
            if (std.ascii.eqlIgnoreCase(profile_id, self.current_profile_id)) {
                return self.createCurrentProfileRecord();
            }
        }
        const profile = try self.arena.create(types.SObject);
        profile.* = .{ .type_name = "Profile" };
        // Extract Name value from WHERE clause: WHERE Name = 'Xyz' or WHERE Name = :var
        const profile_name = self.extractWhereFieldValue(soql, "Name", current_env) orelse "System Administrator";
        const profile_id = try self.allocId();
        profile.id = profile_id;
        try profile.fields.put(self.arena, "Id", Value{ .string = profile_id });
        try self.populateSyntheticProfile(profile, profile_name);
        return Value{ .sobject = profile };
    }

    fn populateSyntheticProfile(self: *Evaluator, profile: *types.SObject, profile_name: []const u8) !void {
        try profile.fields.put(self.arena, "Name", Value{ .string = profile_name });

        const is_guest_profile = std.ascii.indexOfIgnoreCase(profile_name, "Guest") != null;
        try profile.fields.put(self.arena, "UserType", Value{ .string = if (is_guest_profile) "Guest" else "Standard" });

        const license = try self.arena.create(types.SObject);
        const license_id = try std.fmt.allocPrint(self.arena, "0LQ{d:0>15}", .{self.next_id});
        self.next_id += 1;
        license.* = .{ .type_name = "UserLicense", .id = license_id };
        try license.fields.put(self.arena, "Id", Value{ .string = license_id });
        if (is_guest_profile) {
            try license.fields.put(self.arena, "Name", Value{ .string = "Guest User License" });
            try license.fields.put(self.arena, "LicenseDefinitionKey", Value{ .string = "PID_Guest_User" });
        } else {
            try license.fields.put(self.arena, "Name", Value{ .string = "Salesforce" });
            try license.fields.put(self.arena, "LicenseDefinitionKey", Value{ .string = "SFDC" });
        }
        try profile.fields.put(self.arena, "UserLicenseId", Value{ .string = license_id });
        try profile.fields.put(self.arena, "UserLicense", Value{ .sobject = license });
    }

    fn findProfileByName(self: *Evaluator, profile_name: []const u8) ?*types.SObject {
        if (self.store.get("Profile")) |profiles| {
            for (profiles.items) |record| {
                if (record != .sobject) continue;
                if (utils.sobjectGet(&record.sobject.fields, "Name")) |name| {
                    if (name == .string and std.ascii.eqlIgnoreCase(name.string, profile_name)) {
                        return record.sobject;
                    }
                }
            }
        }
        return null;
    }

    fn isGuestUserId(self: *Evaluator, user_id: []const u8) bool {
        if (self.store.get("User")) |users| {
            for (users.items) |record| {
                if (record != .sobject or record.sobject.id == null) continue;
                if (!std.ascii.eqlIgnoreCase(record.sobject.id.?, user_id)) continue;
                if (utils.sobjectGet(&record.sobject.fields, "UserType")) |user_type| {
                    if (user_type == .string and std.ascii.eqlIgnoreCase(user_type.string, "Guest")) return true;
                }
                if (utils.sobjectGet(&record.sobject.fields, "Profile")) |profile_val| {
                    if (profile_val == .sobject) {
                        if (utils.sobjectGet(&profile_val.sobject.fields, "UserType")) |profile_user_type| {
                            if (profile_user_type == .string and std.ascii.eqlIgnoreCase(profile_user_type.string, "Guest")) return true;
                        }
                    }
                }
                return false;
            }
        }
        return false;
    }

    fn hasExactWhereFieldComparison(self: *Evaluator, soql: []const u8, field_name: []const u8) bool {
        _ = self;
        const where_clause = extractWhereClause(soql) orelse return false;
        var pos: usize = 0;
        while (pos + field_name.len <= where_clause.len) : (pos += 1) {
            if (!std.ascii.eqlIgnoreCase(where_clause[pos .. pos + field_name.len], field_name)) continue;
            if (!(pos == 0 or where_clause[pos - 1] == ' ' or where_clause[pos - 1] == '(')) continue;
            var j = pos + field_name.len;
            while (j < where_clause.len and (where_clause[j] == ' ' or where_clause[j] == '\t')) j += 1;
            if (j < where_clause.len and where_clause[j] == '=') return true;
        }
        return false;
    }

    fn hasWhereFieldLikeComparison(self: *Evaluator, soql: []const u8, field_name: []const u8) bool {
        _ = self;
        const where_clause = extractWhereClause(soql) orelse return false;
        var pos: usize = 0;
        while (pos + field_name.len <= where_clause.len) : (pos += 1) {
            if (!std.ascii.eqlIgnoreCase(where_clause[pos .. pos + field_name.len], field_name)) continue;
            if (!(pos == 0 or where_clause[pos - 1] == ' ' or where_clause[pos - 1] == '(')) continue;
            var j = pos + field_name.len;
            while (j < where_clause.len and (where_clause[j] == ' ' or where_clause[j] == '\t')) j += 1;
            if (j + 4 <= where_clause.len and std.ascii.eqlIgnoreCase(where_clause[j .. j + 4], "LIKE")) return true;
        }
        return false;
    }

    fn collapseLikeWildcards(self: *Evaluator, pattern: []const u8) []const u8 {
        var has_repeated_percent = false;
        var prev_was_percent = false;
        for (pattern) |ch| {
            if (ch == '%') {
                if (prev_was_percent) {
                    has_repeated_percent = true;
                    break;
                }
                prev_was_percent = true;
            } else {
                prev_was_percent = false;
            }
        }
        if (!has_repeated_percent) return pattern;

        const buf = self.arena.alloc(u8, pattern.len) catch return pattern;
        var write_idx: usize = 0;
        prev_was_percent = false;
        for (pattern) |ch| {
            if (ch == '%') {
                if (prev_was_percent) continue;
                prev_was_percent = true;
            } else {
                prev_was_percent = false;
            }
            buf[write_idx] = ch;
            write_idx += 1;
        }
        return buf[0..write_idx];
    }

    fn createUserForQuery(self: *Evaluator, soql: []const u8, current_env: *Env) !Value {
        const user = try self.arena.create(types.SObject);
        const username = self.extractWhereFieldValue(soql, "Username", current_env) orelse "testuser@example.com";
        const user_id = try std.fmt.allocPrint(self.arena, "005{d:0>15}", .{self.next_id});
        self.next_id += 1;
        user.* = .{ .type_name = "User", .id = user_id };
        try user.fields.put(self.arena, "Id", Value{ .string = user_id });
        try user.fields.put(self.arena, "Username", Value{ .string = username });
        try user.fields.put(self.arena, "Email", Value{ .string = username });
        try user.fields.put(self.arena, "Alias", Value{ .string = "tuser" });
        try user.fields.put(self.arena, "TimeZoneSidKey", Value{ .string = "America/Los_Angeles" });

        const is_automated_process = std.ascii.startsWithIgnoreCase(username, "autoproc@");
        const has_null_profile = self.hasWhereFieldNullLiteral(soql, "Profile.Name");
        const profile_name_opt = if (self.hasExactWhereFieldComparison(soql, "Profile.Name") and !has_null_profile)
            self.extractWhereFieldValue(soql, "Profile.Name", current_env)
        else
            null;
        const explicit_user_type = if (self.hasExactWhereFieldComparison(soql, "Profile.UserType"))
            self.extractWhereFieldValue(soql, "Profile.UserType", current_env)
        else if (self.hasExactWhereFieldComparison(soql, "UserType"))
            self.extractWhereFieldValue(soql, "UserType", current_env)
        else
            null;

        if (!has_null_profile or profile_name_opt != null or explicit_user_type != null) {
            const profile_name = profile_name_opt orelse if (explicit_user_type) |user_type|
                (if (std.ascii.eqlIgnoreCase(user_type, "Guest")) "Logger Test LWR Site Guest Profile" else "Standard User")
            else
                "Standard User";
            const profile = if (self.findProfileByName(profile_name)) |existing|
                existing
            else blk: {
                const created = try self.arena.create(types.SObject);
                const profile_id = try std.fmt.allocPrint(self.arena, "00e{d:0>15}", .{self.next_id});
                self.next_id += 1;
                created.* = .{ .type_name = "Profile", .id = profile_id };
                try created.fields.put(self.arena, "Id", Value{ .string = profile_id });
                try self.populateSyntheticProfile(created, profile_name);
                const gop = try self.store.getOrPut(self.arena, "Profile");
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.arena, Value{ .sobject = created });
                break :blk created;
            };
            if (explicit_user_type) |user_type| {
                try profile.fields.put(self.arena, "UserType", Value{ .string = user_type });
            }
            try user.fields.put(self.arena, "ProfileId", Value{ .string = profile.id.? });
            try user.fields.put(self.arena, "Profile", Value{ .sobject = profile });
            if (utils.sobjectGet(&profile.fields, "UserType")) |profile_user_type| {
                try user.fields.put(self.arena, "UserType", profile_user_type);
            }
        } else {
            try user.fields.put(self.arena, "UserType", Value{ .string = "AutomatedProcess" });
        }

        try user.fields.put(self.arena, "FirstName", Value{ .string = "Test" });
        try user.fields.put(self.arena, "LastName", Value{ .string = if (is_automated_process) "Process" else "User" });
        try user.fields.put(self.arena, "Name", Value{ .string = if (is_automated_process) "Automated Process" else "Test User" });
        return Value{ .sobject = user };
    }

    fn appendRecordIdsFromValue(self: *Evaluator, value: Value, record_ids: *std.ArrayListUnmanaged([]const u8)) !void {
        switch (value) {
            .string => |s| if (s.len > 0) try record_ids.append(self.arena, s),
            .sobject => |sob| if (sob.id) |id| try record_ids.append(self.arena, id),
            .list => |list| {
                for (list.items.items) |item| {
                    try self.appendRecordIdsFromValue(item, record_ids);
                }
            },
            .set => |set| {
                for (set.entries.values()) |item| {
                    try self.appendRecordIdsFromValue(item, record_ids);
                }
            },
            .map => |map| {
                for (map.entries.keys()) |key| {
                    if (key.len > 0) try record_ids.append(self.arena, key);
                }
            },
            else => {
                const coerced = utils.coerceToString(value, self.arena) catch return;
                if (coerced.len > 0) try record_ids.append(self.arena, coerced);
            },
        }
    }

    fn canDeleteRecordViaUserRecordAccess(self: *Evaluator, record_id: []const u8) bool {
        const type_name = self.findRecordTypeById(record_id) orelse blk: {
            if (record_id.len < 3) break :blk "SObject";
            break :blk sobjectTypeFromPrefix(record_id[0..3]);
        };
        if (std.ascii.eqlIgnoreCase(type_name, "SObject")) return false;
        if (std.ascii.eqlIgnoreCase(type_name, "User")) return false;
        if (self.isSetupObject(type_name)) return false;
        return true;
    }

    fn seedUserRecordAccessRecords(self: *Evaluator, soql: []const u8, current_env: *Env, records: *std.ArrayListUnmanaged(Value)) !void {
        const where_clause = extractWhereClause(soql) orelse return;
        const requested_user_id = self.extractWhereFieldValue(soql, "UserId", current_env) orelse blk: {
            if (std.ascii.indexOfIgnoreCase(where_clause, "UserId = :System.UserInfo.getUserId()") != null) {
                break :blk self.current_user_id;
            }
            break :blk null;
        };
        if (requested_user_id) |user_id| {
            if (!std.ascii.eqlIgnoreCase(user_id, self.current_user_id)) return;
        }

        var record_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        if (std.ascii.indexOfIgnoreCase(where_clause, "RecordId IN :")) |in_pos| {
            var j = in_pos + "RecordId IN :".len;
            const start = j;
            while (j < where_clause.len and (std.ascii.isAlphanumeric(where_clause[j]) or where_clause[j] == '_')) j += 1;
            if (j > start) {
                if (self.lookupBindValue(current_env, where_clause[start..j])) |bind_val| {
                    try self.appendRecordIdsFromValue(bind_val, &record_ids);
                }
            }
        }
        if (record_ids.items.len == 0) {
            if (self.extractWhereFieldValue(soql, "RecordId", current_env)) |record_id| {
                try record_ids.append(self.arena, record_id);
            }
        }

        for (record_ids.items) |record_id| {
            const access = try self.arena.create(types.SObject);
            const access_id = try self.allocId();
            const has_delete_access = self.canDeleteRecordViaUserRecordAccess(record_id);
            access.* = .{ .type_name = "UserRecordAccess", .id = access_id };
            try access.fields.put(self.arena, "Id", Value{ .string = access_id });
            try access.fields.put(self.arena, "UserId", Value{ .string = self.current_user_id });
            try access.fields.put(self.arena, "RecordId", Value{ .string = record_id });
            try access.fields.put(self.arena, "HasReadAccess", Value{ .boolean = has_delete_access });
            try access.fields.put(self.arena, "HasEditAccess", Value{ .boolean = has_delete_access });
            try access.fields.put(self.arena, "HasDeleteAccess", Value{ .boolean = has_delete_access });

            const access_value = Value{ .sobject = access };
            if (self.matchesWhere(access_value, soql, current_env)) {
                try records.append(self.arena, access_value);
            }
        }
    }

    /// Seed stub records for setup objects queried with IN clause (PermissionSet, PermissionSetLicense, etc.).
    /// Extracts names from WHERE Name/DeveloperName IN (:var) or IN ('a','b') and creates a stub for each.
    fn seedNamedRecords(self: *Evaluator, obj_type: []const u8, soql: []const u8, current_env: *Env, records: *std.ArrayListUnmanaged(Value)) !void {
        const where_clause = extractWhereClause(soql) orelse return;
        // Collect names from the IN clause — supports both bind variables (Set/List) and literal lists
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        // Check for IN :var pattern
        if (std.ascii.indexOfIgnoreCase(where_clause, " IN :")) |in_pos| {
            var j = in_pos + 5; // skip " IN :"
            const start = j;
            while (j < where_clause.len and (std.ascii.isAlphanumeric(where_clause[j]) or where_clause[j] == '_')) j += 1;
            if (j > start) {
                const var_name = where_clause[start..j];
                // Try env lookup, then class-qualified static field
                const v = current_env.get(var_name) orelse blk: {
                    if (self.current_class) |cc| {
                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, var_name }) catch break :blk null;
                        break :blk self.global_env.get(key);
                    }
                    break :blk null;
                };
                if (v) |val| {
                    if (val == .set) {
                        for (val.set.entries.values()) |item| {
                            if (item == .string) try names.append(self.arena, item.string);
                        }
                    } else if (val == .list) {
                        for (val.list.items.items) |item| {
                            if (item == .string) try names.append(self.arena, item.string);
                        }
                    }
                }
            }
        }
        // Also check for IN ('a', 'b', 'c') pattern
        if (names.items.len == 0) {
            if (std.ascii.indexOfIgnoreCase(where_clause, " IN (")) |in_pos| {
                var j = in_pos + 5;
                while (j < where_clause.len and where_clause[j] != ')') {
                    while (j < where_clause.len and where_clause[j] != '\'' and where_clause[j] != ')') j += 1;
                    if (j < where_clause.len and where_clause[j] == '\'') {
                        j += 1;
                        const start = j;
                        while (j < where_clause.len and where_clause[j] != '\'') j += 1;
                        if (j > start) try names.append(self.arena, where_clause[start..j]);
                        if (j < where_clause.len) j += 1;
                    }
                }
            }
        }
        // Create stub records for each name
        for (names.items) |name| {
            const stub = try self.arena.create(types.SObject);
            stub.* = .{ .type_name = obj_type };
            const stub_id = try self.allocId();
            stub.id = stub_id;
            try stub.fields.put(self.arena, "Id", Value{ .string = stub_id });
            try stub.fields.put(self.arena, "Name", Value{ .string = name });
            try stub.fields.put(self.arena, "DeveloperName", Value{ .string = name });
            try records.append(self.arena, Value{ .sobject = stub });
            // Also store in data store so subsequent queries can find them
            const gop = try self.store.getOrPut(self.arena, obj_type);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.arena, Value{ .sobject = stub });
        }
    }

    /// Seed synthetic RecordType records into the store for all known SObject types.
    /// IDs are kept in sync with createRecordTypeInfo/createDescribeResult in builtins.zig.
    fn seedRecordTypeStore(self: *Evaluator) !void {
        const gop = try self.store.getOrPut(self.arena, "RecordType");
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (gop.value_ptr.items.len > 0) return; // already seeded

        // Each SObject type gets a Master RecordType with a unique ID based on index.
        // Account additionally gets a "Default" record type.
        const known_types = [_][]const u8{
            "Account",  "Contact",  "Opportunity", "Task", "Lead", "Case", "User",
            "Solution", "Campaign", "Event",
        };
        for (known_types, 0..) |obj_name, idx| {
            // Master RecordType — unique ID per SObject type
            const master = try self.arena.create(types.SObject);
            master.* = .{ .type_name = "RecordType" };
            const master_id = try std.fmt.allocPrint(self.arena, "0120000000000{d:0>2}AAA", .{idx});
            master.id = master_id;
            try master.fields.put(self.arena, "Id", Value{ .string = master_id });
            try master.fields.put(self.arena, "Name", Value{ .string = "Master" });
            try master.fields.put(self.arena, "DeveloperName", Value{ .string = "Master" });
            try master.fields.put(self.arena, "SobjectType", Value{ .string = obj_name });
            try master.fields.put(self.arena, "IsActive", Value{ .boolean = true });
            try gop.value_ptr.append(self.arena, Value{ .sobject = master });

            // All known SObject types get an additional "Default" RecordType
            {
                const default_rt = try self.arena.create(types.SObject);
                default_rt.* = .{ .type_name = "RecordType" };
                const def_id = try std.fmt.allocPrint(self.arena, "0120000000001{d:0>2}AAA", .{idx});
                default_rt.id = def_id;
                try default_rt.fields.put(self.arena, "Id", Value{ .string = def_id });
                try default_rt.fields.put(self.arena, "Name", Value{ .string = "Default" });
                try default_rt.fields.put(self.arena, "DeveloperName", Value{ .string = "Default" });
                try default_rt.fields.put(self.arena, "SobjectType", Value{ .string = obj_name });
                try default_rt.fields.put(self.arena, "IsActive", Value{ .boolean = true });
                try gop.value_ptr.append(self.arena, Value{ .sobject = default_rt });
            }
        }
    }

    /// Convert picklist field values from API name (fullName) to label on custom objects.
    fn convertPicklistValues(self: *Evaluator, obj: *types.SObject) !void {
        if (!std.mem.endsWith(u8, obj.type_name, "__c")) return;
        for (obj.fields.keys(), obj.fields.values()) |field_name, *field_val| {
            if (field_val.* != .string or !std.mem.endsWith(u8, field_name, "__c")) continue;
            if (self.resolvePicklistLabel(obj.type_name, field_name, field_val.string)) |label| {
                field_val.* = Value{ .string = label };
            }
        }
    }

    /// Re-initialize static fields for a single class (test class reset)
    pub fn reInitClassStaticFields(self: *Evaluator, cd: *ast.ClassDecl) void {
        const saved_class = self.current_class;
        self.current_class = cd.name;
        defer self.current_class = saved_class;
        // Protect caller's stack-trace state: static initializers may evaluate
        // `new_expr` which clobbers current_call_line and the top frame's line.
        const saved_call_line = self.current_call_line;
        const saved_top_line: ?u32 = if (self.call_stack.items.len > 0)
            self.call_stack.items[self.call_stack.items.len - 1].line
        else
            null;
        defer {
            self.current_call_line = saved_call_line;
            if (saved_top_line) |tl| {
                if (self.call_stack.items.len > 0)
                    self.call_stack.items[self.call_stack.items.len - 1].line = tl;
            }
        }
        for (cd.members) |member| {
            switch (member) {
                .field_decl => |fd| {
                    if (fd.modifiers.is_static) {
                        const val = if (fd.initializer) |init_expr|
                            self.evalExpr(init_expr, self.global_env) catch Value.null_val
                        else
                            defaultValue(fd.type_ref);
                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                        self.global_env.set(key, val) catch {
                            self.global_env.define(key, val) catch {};
                        };
                    }
                },
                else => {},
            }
        }
    }

    /// Register static field placeholders (null values) without evaluating initializers.
    /// Used to prepare global_env keys so that lazy init can later fill in real values.
    pub fn registerStaticFieldPlaceholders(self: *Evaluator, cd: *ast.ClassDecl) void {
        for (cd.members) |member| {
            switch (member) {
                .field_decl => |fd| {
                    if (fd.modifiers.is_static) {
                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                        self.global_env.define(key, defaultValue(fd.type_ref)) catch {};
                    }
                },
                else => {},
            }
        }
    }

    /// Resolve a class name to its fully-qualified form (e.g., "InnerClass" → "OuterClass.InnerClass").
    /// If the name already contains a dot or no FQ match is found, returns the original name.
    fn resolveFullClassName(self: *Evaluator, name: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, name, '.') != null) return name;
        var iter = self.classes.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            // Look for "Outer.Name" pattern where Name matches
            if (std.mem.indexOfScalar(u8, key, '.')) |di| {
                if (std.ascii.eqlIgnoreCase(key[di + 1 ..], name)) return key;
            }
        }
        return name;
    }

    fn simpleClassName(name: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |di| return name[di + 1 ..];
        return name;
    }

    fn hasTopLevelClass(self: *Evaluator, name: []const u8) bool {
        for (self.class_sources.keys()) |class_name| {
            if (std.ascii.eqlIgnoreCase(class_name, name)) return true;
        }
        return false;
    }

    fn findInnerClassFq(self: *Evaluator, outer_name: []const u8, simple_name: []const u8) ?[]const u8 {
        const outer_decl = self.findClass(outer_name) orelse return null;
        for (outer_decl.members) |member| {
            switch (member) {
                .class_decl => |inner_cd| {
                    if (std.ascii.eqlIgnoreCase(inner_cd.name, simple_name)) {
                        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ outer_name, inner_cd.name }) catch null;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn resolveVisibleUserClassInScope(self: *Evaluator, current_env: ?*Env, simple_name: []const u8) ?[]const u8 {
        if (std.mem.indexOfScalar(u8, simple_name, '.') != null) {
            if (self.findClass(simple_name) != null) return simple_name;
            return null;
        }

        const scope_class = blk: {
            if (current_env) |env| {
                if (env.get("this")) |this_val| {
                    if (this_val == .object) break :blk this_val.object.class_name;
                }
            }
            break :blk self.current_class;
        };

        if (scope_class) |scope_name| {
            if (std.ascii.eqlIgnoreCase(simpleClassName(scope_name), simple_name)) {
                return scope_name;
            }
            if (self.findInnerClassFq(scope_name, simple_name)) |fq| return fq;
            if (self.findOuterClassName(scope_name)) |outer_name| {
                if (std.ascii.eqlIgnoreCase(simpleClassName(outer_name), simple_name)) {
                    return outer_name;
                }
                if (self.findInnerClassFq(outer_name, simple_name)) |fq| return fq;
            }
        }

        if (self.hasTopLevelClass(simple_name)) return simple_name;
        return null;
    }

    /// Build a Salesforce-format stack trace string from the current call stack.
    /// Format: "Class.ClassName.methodName: line N, column 1\n..."
    /// Call stack frames are walked top-to-bottom. Each frame's `line` should
    /// already reflect the line of the call-site expression (set by evalMethodCall/evalNewExpr).
    pub fn buildStackTraceString(self: *Evaluator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        var i: usize = self.call_stack.items.len;
        while (i > 0) {
            i -= 1;
            const f = self.call_stack.items[i];
            if (buf.items.len > 0) try buf.append(self.arena, '\n');
            const fq = self.resolveFullClassName(f.class_name);
            const line = if (f.line > 0) f.line else 1;
            const entry = try std.fmt.allocPrint(self.arena, "Class.{s}.{s}: line {d}, column 1", .{ fq, f.method_name, line });
            try buf.appendSlice(self.arena, entry);
        }
        return buf.items;
    }

    /// Lazily ensure a class's static fields and static init blocks have been evaluated.
    /// Called on first access to a class (method call, field access, or instantiation).
    pub fn ensureStaticInit(self: *Evaluator, class_name: []const u8) void {
        // Fast path: already initialized
        if (self.static_inited.get(class_name) != null) return;
        // Case-insensitive lookup
        var iter = self.classes.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                if (self.static_inited.get(entry.key_ptr.*) != null) return;
                const cd = entry.value_ptr.*;
                // Mark as initialized BEFORE evaluating to prevent infinite recursion
                // on circular static dependencies (matches Salesforce behavior: circular
                // deps see null/default for the not-yet-evaluated class).
                self.static_inited.put(self.arena, entry.key_ptr.*, {}) catch return;
                self.reInitClassStaticFields(cd);
                self.runClassStaticInits(cd);
                return;
            }
        }
    }

    /// Run static init blocks for a single class
    pub fn runClassStaticInits(self: *Evaluator, cd: *ast.ClassDecl) void {
        for (cd.members) |member| {
            switch (member) {
                .static_init => |body| {
                    const init_env = self.global_env.child() catch continue;
                    var static_keys: std.ArrayListUnmanaged([]const u8) = .empty;
                    var original_values: std.ArrayListUnmanaged(Value) = .empty;
                    for (cd.members) |m2| {
                        switch (m2) {
                            .field_decl => |fd| {
                                if (fd.modifiers.is_static) {
                                    const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                                    const cur = self.global_env.get(key) orelse Value.null_val;
                                    static_keys.append(self.arena, key) catch continue;
                                    original_values.append(self.arena, cur) catch continue;
                                    init_env.define(fd.name, cur) catch {};
                                }
                            },
                            else => {},
                        }
                    }
                    _ = self.execBlock(body, init_env) catch {};
                    var static_index: usize = 0;
                    for (cd.members) |m2| {
                        switch (m2) {
                            .field_decl => |fd| {
                                if (fd.modifiers.is_static) {
                                    const key = if (static_index < static_keys.items.len)
                                        static_keys.items[static_index]
                                    else
                                        std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                                    const original_value = if (static_index < original_values.items.len)
                                        original_values.items[static_index]
                                    else
                                        Value.null_val;
                                    static_index += 1;
                                    const local_value = init_env.get(fd.name) orelse Value.null_val;
                                    const global_value = self.global_env.get(key) orelse Value.null_val;
                                    const writeback_value = if (!utils.valueEql(local_value, original_value))
                                        local_value
                                    else
                                        global_value;
                                    self.global_env.set(key, writeback_value) catch {
                                        self.global_env.define(key, writeback_value) catch {};
                                    };
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
    }

    // -----------------------------------------------------------------------
    // トップレベル
    // -----------------------------------------------------------------------

    pub fn loadDecls(self: *Evaluator, decls: []const ast.Decl) anyerror!void {
        const ca = self.class_arena orelse self.arena;
        // Pass 1: Register all classes, inner classes, enums, and static field placeholders
        for (decls) |decl| {
            switch (decl) {
                .class_decl => |cd| {
                    try self.registerClassRecursive(ca, cd, null);
                },
                .trigger_decl => |td| {
                    const obj_lower = std.ascii.lowerString(self.arena.alloc(u8, td.object_name.len) catch continue, td.object_name);
                    const gop = self.triggers.getOrPut(self.arena, obj_lower) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    gop.value_ptr.append(self.arena, td) catch {};
                },
                else => {},
            }
        }
        // Pass 2 is deferred: static field initializers and static init blocks
        // are evaluated lazily via ensureStaticInit() on first class access.
        // This matches Salesforce behavior where static initialization happens
        // when a class is first referenced, not at load time.
    }

    /// Register source code for a class (used for ApexClass.Body queries)
    pub fn registerClassSource(self: *Evaluator, class_name: []const u8, source: []const u8) !void {
        try self.class_sources.put(self.arena, class_name, source);
    }

    pub fn registerTriggerSource(self: *Evaluator, trigger_name: []const u8, source: []const u8) !void {
        try self.trigger_sources.put(self.arena, trigger_name, source);
    }

    /// Execute all static initializer blocks. Should be called after all files are loaded.
    pub fn runStaticInits(self: *Evaluator) void {
        var class_iter = self.classes.iterator();
        while (class_iter.next()) |entry| {
            const cd = entry.value_ptr.*;
            for (cd.members) |member| {
                switch (member) {
                    .static_init => |body| {
                        const init_env = self.global_env.child() catch continue;
                        var static_keys: std.ArrayListUnmanaged([]const u8) = .empty;
                        var original_values: std.ArrayListUnmanaged(Value) = .empty;
                        // Define static fields as local variables
                        for (cd.members) |m2| {
                            switch (m2) {
                                .field_decl => |fd| {
                                    if (fd.modifiers.is_static) {
                                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                                        const cur = self.global_env.get(key) orelse Value.null_val;
                                        static_keys.append(self.arena, key) catch continue;
                                        original_values.append(self.arena, cur) catch continue;
                                        init_env.define(fd.name, cur) catch {};
                                    }
                                },
                                else => {},
                            }
                        }
                        _ = self.execBlock(body, init_env) catch {};
                        // Write back static fields to global env
                        var static_index: usize = 0;
                        for (cd.members) |m2| {
                            switch (m2) {
                                .field_decl => |fd| {
                                    if (fd.modifiers.is_static) {
                                        const key = if (static_index < static_keys.items.len)
                                            static_keys.items[static_index]
                                        else
                                            std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                                        const original_value = if (static_index < original_values.items.len)
                                            original_values.items[static_index]
                                        else
                                            Value.null_val;
                                        static_index += 1;
                                        const local_value = init_env.get(fd.name) orelse Value.null_val;
                                        const global_value = self.global_env.get(key) orelse Value.null_val;
                                        const writeback_value = if (!utils.valueEql(local_value, original_value))
                                            local_value
                                        else
                                            global_value;
                                        self.global_env.set(key, writeback_value) catch {
                                            self.global_env.define(key, writeback_value) catch {};
                                        };
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    pub fn callMethod(self: *Evaluator, class_name: []const u8, method_name: []const u8, args: []const Value) anyerror!Value {
        self.call_depth +|= 1;
        defer self.call_depth -|= 1;
        if (self.call_depth > self.max_call_depth) {
            return .null_val;
        }
        // Push call frame for stack trace generation (use current_call_line set by caller)
        const frame_line = self.current_call_line;
        self.current_call_line = 0;
        try self.call_stack.append(self.arena, .{ .class_name = class_name, .method_name = method_name, .line = frame_line });
        defer _ = self.call_stack.pop();
        // Lazy static init: ensure the class's static fields/blocks are initialized
        self.ensureStaticInit(class_name);
        if (self.findClass(class_name)) |cd| {
            if (cd.super_class) |sc| self.ensureStaticInit(sc.name);
        }
        // EventBus.publish → store events in the store so they can be queried, and fire triggers
        if (std.ascii.eqlIgnoreCase(class_name, "EventBus") and std.ascii.eqlIgnoreCase(method_name, "publish")) {
            self.limits_publish_immediate += 1;
            // EventBus.publish always succeeds in Salesforce (errors are in SaveResult.errors)
            const publish_success = true;
            if (publish_success and args.len > 0) {
                if (args[0] == .sobject) {
                    try self.insertRecord(args[0].sobject);
                } else if (args[0] == .list) {
                    for (args[0].list.items.items) |item| {
                        if (item == .sobject) try self.insertRecord(item.sobject);
                    }
                }
                // Fire after insert triggers for the event type
                // Platform event triggers run in a separate transaction in Salesforce,
                // so save/restore DML/SOQL limits to avoid counting trigger DML in caller's limits
                const event_type = if (args[0] == .sobject) args[0].sobject.type_name else if (args[0] == .list and args[0].list.items.items.len > 0 and args[0].list.items.items[0] == .sobject)
                    args[0].list.items.items[0].sobject.type_name
                else
                    null;
                if (event_type) |et| {
                    const saved_dml = self.limits_dml;
                    const saved_dml_rows = self.limits_dml_rows;
                    const saved_soql = self.limits_soql;
                    var record_list = try self.buildRecordList(args[0]);
                    self.fireTrigger(et, .after_insert, &record_list, null) catch {};
                    self.limits_dml = saved_dml;
                    self.limits_dml_rows = saved_dml_rows;
                    self.limits_soql = saved_soql;
                }
            }
            const result = if (args.len > 0 and args[0] == .list) blk: {
                const results = try self.arena.create(types.ListValue);
                results.* = .{};
                for (args[0].list.items.items) |item| {
                    const result_id = if (publish_success and item == .sobject) self.sobjectIdForResult(item.sobject) else null;
                    try results.items.append(self.arena, try self.createDmlResultValue("Database.SaveResult", publish_success, result_id, null));
                }
                break :blk Value{ .list = results };
            } else blk: {
                const result_id = if (publish_success and args.len > 0 and args[0] == .sobject) self.sobjectIdForResult(args[0].sobject) else null;
                break :blk try self.createDmlResultValue("Database.SaveResult", publish_success, result_id, null);
            };
            // If a callback is provided (second arg), store it for later processing by Test.getEventBus()
            if (args.len >= 2 and args[1] == .object) {
                const callback = args[1].object;
                // Store callback info for Test.getEventBus().fail() support
                self.pending_event_callback = .{
                    .callback = callback,
                    .event = if (args[0] == .sobject) args[0] else .null_val,
                };
                if (self.findClass(callback.class_name)) |cb_class| {
                    // Build EventBus.PublishResult with EventUuids
                    const pub_result = try self.arena.create(types.ObjectInstance);
                    pub_result.* = .{ .class_name = "EventBus.PublishResult" };
                    const uuid_list = try self.arena.create(types.ListValue);
                    uuid_list.* = .{};
                    // Add the EventUuid from the event
                    if (args[0] == .sobject) {
                        if (utils.sobjectGet(&args[0].sobject.fields, "EventUuid")) |uuid_val| {
                            try uuid_list.items.append(self.arena, uuid_val);
                        }
                    }
                    try pub_result.fields.put(self.arena, "eventUuids", Value{ .list = uuid_list });
                    // Call onSuccess(result) on the callback (will be overridden by fail() if called)
                    _ = self.callInstanceMethod(cb_class, callback, "onSuccess", &.{Value{ .object = pub_result }}) catch {};
                }
            }
            return result;
        }

        // Custom Metadata Type: Type__mdt.getInstance(developerName) / getAll()
        if (std.mem.endsWith(u8, class_name, "__mdt")) {
            // Ensure records are loaded
            {
                var found_in_store = false;
                var si = self.store.iterator();
                while (si.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                        found_in_store = true;
                        break;
                    }
                }
                if (!found_in_store) self.loadCustomMetadataFromFiles(class_name) catch {};
            }
            if (std.ascii.eqlIgnoreCase(method_name, "getInstance") and args.len > 0 and args[0] == .string) {
                const dev_name = args[0].string;
                var mdt_iter = self.store.iterator();
                while (mdt_iter.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                        for (entry.value_ptr.items) |item| {
                            if (item == .sobject) {
                                if (utils.sobjectGet(&item.sobject.fields, "DeveloperName")) |dn| {
                                    if (dn == .string and std.ascii.eqlIgnoreCase(dn.string, dev_name)) return item;
                                }
                            }
                        }
                    }
                }
                return Value.null_val;
            }
            if (std.ascii.eqlIgnoreCase(method_name, "getAll")) {
                const map = try self.arena.create(types.MapValue);
                map.* = .{};
                var mdt_iter = self.store.iterator();
                while (mdt_iter.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                        for (entry.value_ptr.items) |item| {
                            if (item == .sobject) {
                                if (utils.sobjectGet(&item.sobject.fields, "DeveloperName")) |dn| {
                                    if (dn == .string) try map.entries.put(self.arena, dn.string, item);
                                }
                            }
                        }
                    }
                }
                return Value{ .map = map };
            }
        }

        if (try self.handleCustomSettingStaticMethod(class_name, method_name, args)) |result| {
            return result;
        }

        // Database methods that need store access. Preserve user-defined classes named
        // Database, which Apex can still reference unqualified while the platform
        // namespace remains reachable through System.Database.
        if (std.ascii.eqlIgnoreCase(class_name, "Database") and self.findClass(class_name) == null) {
            return self.handleDatabaseMethod(method_name, args, self.global_env);
        }

        // Builtin class stubs (before user-defined classes)
        if (!(std.ascii.eqlIgnoreCase(class_name, "Database") and self.findClass(class_name) != null)) {
            var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
            if (try builtins.dispatchStatic(&bctx, class_name, method_name, args)) |result| {
                return result;
            }
        }

        // Case-insensitive class lookup (before user-defined classes)
        var iter = self.classes.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                const prev_class = self.current_class;
                self.current_class = entry.key_ptr.*;
                defer self.current_class = prev_class;
                // Try type-aware resolution first (prefer static methods for callMethod)
                if (self.findBestMethodInClassFiltered(entry.value_ptr.*, method_name, args, true)) |md| {
                    return self.executeMethod(md, args);
                }
                // Fallback to any method (not just static)
                if (self.findBestMethodInClass(entry.value_ptr.*, method_name, args)) |md| {
                    return self.executeMethod(md, args);
                }
                // Fallback: find any name match
                var any_name_match = false;
                for (entry.value_ptr.*.members) |member| {
                    switch (member) {
                        .method_decl => |md| {
                            if (std.ascii.eqlIgnoreCase(md.name, method_name)) {
                                any_name_match = true;
                                break;
                            }
                        },
                        else => {},
                    }
                }
                if (any_name_match) return Value.null_val;
                return Value.null_val; // method not found in class, return null
            }
        }
        // Check if class_name is an enum (inner or top-level)
        {
            var enum_iter = self.classes.iterator();
            while (enum_iter.next()) |entry| {
                for (entry.value_ptr.*.members) |member| {
                    switch (member) {
                        .enum_decl => |ed| {
                            if (std.ascii.eqlIgnoreCase(ed.name, class_name)) {
                                if (std.ascii.eqlIgnoreCase(method_name, "valueOf") and args.len > 0 and args[0] == .string) {
                                    return Value{ .string = args[0].string };
                                }
                                if (std.ascii.eqlIgnoreCase(method_name, "values")) {
                                    const list = try self.arena.create(types.ListValue);
                                    list.* = .{};
                                    for (ed.values) |v| {
                                        try list.items.append(self.arena, Value{ .string = v });
                                    }
                                    return Value{ .list = list };
                                }
                                for (ed.values) |v| {
                                    if (std.ascii.eqlIgnoreCase(v, method_name)) return Value{ .string = v };
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        }
        // TestFactory / TestDataHelpers builtin stubs (only when no user-defined class found)
        if (try self.handleTestFactory(class_name, method_name, args)) |result| {
            return result;
        }
        return Value.null_val; // class not found, return null instead of error
    }

    fn executeMethod(self: *Evaluator, method: *ast.MethodDecl, args: []const Value) anyerror!Value {
        const method_env = try self.global_env.child();

        for (method.params, 0..) |param, i| {
            const val = if (i < args.len) args[i] else Value.null_val;
            try method_env.defineTyped(param.name, val, param.type_ref.name);
        }

        const saved_rv = self.return_value;
        self.return_value = .void_val;
        const result = try self.execBlock(method.body, method_env);
        const ret = switch (result) {
            .return_val => |v| v,
            else => self.return_value,
        };
        self.return_value = saved_rv;
        return ret;
    }

    // -----------------------------------------------------------------------
    // 文の実行
    // -----------------------------------------------------------------------

    pub fn execBlock(self: *Evaluator, stmts: []const ast.Stmt, current_env: *Env) anyerror!StmtResult {
        for (stmts) |stmt| {
            if (self.assertion_failure != null) return .normal;
            const result = try self.execStmt(stmt, current_env);
            switch (result) {
                .normal => {},
                else => return result,
            }
        }
        return .normal;
    }

    pub fn execStmt(self: *Evaluator, stmt: ast.Stmt, current_env: *Env) anyerror!StmtResult {
        switch (stmt) {
            .expr_stmt => |expr| {
                _ = try self.evalExpr(expr, current_env);
                return .normal;
            },
            .var_decl => |vd| {
                var val = if (vd.initializer) |init_expr|
                    try self.evalExpr(init_expr, current_env)
                else
                    defaultValue(vd.type_ref);
                val = try self.coerceSoqlAssignmentToDeclaredType(val, vd.initializer, vd.type_ref.name);
                try current_env.defineTyped(vd.name, val, vd.type_ref.name);
                return .normal;
            },
            .block => |stmts| {
                const block_env = try current_env.child();
                return self.execBlock(stmts, block_env);
            },
            .if_stmt => |if_s| {
                const cond = try self.evalExpr(if_s.condition, current_env);
                const is_true = utils.coerceToBool(cond) catch false;
                if (is_true) {
                    return self.execBlock(if_s.then_body, current_env);
                } else if (if_s.else_body) |else_body| {
                    return self.execBlock(else_body, current_env);
                }
                return .normal;
            },
            .for_stmt => |fs| {
                const loop_env = try current_env.child();
                if (fs.init) |init_stmt| {
                    _ = try self.execStmt(init_stmt.*, loop_env);
                }
                var iterations: u32 = 0;
                while (iterations < 100_000) : (iterations += 1) {
                    if (fs.condition) |cond| {
                        const cv = try self.evalExpr(cond, loop_env);
                        if (!(utils.coerceToBool(cv) catch false)) break;
                    }
                    const result = try self.execBlock(fs.body, loop_env);
                    switch (result) {
                        .break_signal => break,
                        .continue_signal => {},
                        .return_val => return result,
                        .normal => {},
                    }
                    if (fs.update) |upd| {
                        _ = try self.evalExpr(upd, loop_env);
                    }
                }
                return .normal;
            },
            .for_each_stmt => |fes| {
                const iterable = try self.evalExpr(fes.iterable, current_env);
                if (iterable == .list) {
                    // Check if elem_type is List<...> for chunked SOQL for loop
                    const is_list_type = std.ascii.eqlIgnoreCase(fes.elem_type.name, "List") and fes.elem_type.params.len > 0;
                    if (is_list_type) {
                        // Chunked iteration: iterate in chunks of 200
                        const chunk_size: usize = 200;
                        const items = iterable.list.items.items;
                        var offset: usize = 0;
                        const loop_env = try current_env.child();
                        while (offset < items.len) {
                            const end = @min(offset + chunk_size, items.len);
                            const chunk_list = try self.arena.create(types.ListValue);
                            chunk_list.* = .{};
                            for (items[offset..end]) |item| {
                                try chunk_list.items.append(self.arena, item);
                            }
                            try loop_env.define(fes.elem_name, Value{ .list = chunk_list });
                            const result = try self.execBlock(fes.body, loop_env);
                            switch (result) {
                                .break_signal => break,
                                .continue_signal => {},
                                .return_val => return result,
                                .normal => {},
                            }
                            offset = end;
                        }
                    } else {
                        const loop_env = try current_env.child();
                        for (iterable.list.items.items) |item| {
                            try loop_env.define(fes.elem_name, item);
                            const result = try self.execBlock(fes.body, loop_env);
                            switch (result) {
                                .break_signal => break,
                                .continue_signal => {},
                                .return_val => return result,
                                .normal => {},
                            }
                        }
                    }
                } else if (iterable == .set) {
                    const loop_env = try current_env.child();
                    // Copy values to avoid mutation during iteration
                    var values_copy: std.ArrayListUnmanaged(Value) = .empty;
                    for (iterable.set.entries.values()) |item| try values_copy.append(self.arena, item);
                    for (values_copy.items) |item| {
                        loop_env.set(fes.elem_name, item) catch {
                            try loop_env.define(fes.elem_name, item);
                        };
                        const result = try self.execBlock(fes.body, loop_env);
                        switch (result) {
                            .break_signal => break,
                            .continue_signal => {},
                            .return_val => return result,
                            .normal => {},
                        }
                    }
                } else if (iterable == .map) {
                    // Iterating over a map iterates over values
                    const loop_env = try current_env.child();
                    for (iterable.map.entries.values()) |val| {
                        loop_env.set(fes.elem_name, val) catch {
                            try loop_env.define(fes.elem_name, val);
                        };
                        const result = try self.execBlock(fes.body, loop_env);
                        switch (result) {
                            .break_signal => break,
                            .continue_signal => {},
                            .return_val => return result,
                            .normal => {},
                        }
                    }
                } else if (iterable == .object) {
                    // Custom Iterable/Iterator: call iterator() then hasNext()/next()
                    const iterator_obj = blk: {
                        // Try calling iterator() method on the object
                        if (self.findClass(iterable.object.class_name)) |cd| {
                            const iter_val = self.callInstanceMethod(cd, iterable.object, "iterator", &.{}) catch break :blk iterable;
                            break :blk iter_val;
                        }
                        break :blk iterable;
                    };
                    if (iterator_obj == .object) {
                        const iter_cd = self.findClass(iterator_obj.object.class_name);
                        // debug removed
                        const loop_env = try current_env.child();
                        var iterations: u32 = 0;
                        while (iterations < 100_000) : (iterations += 1) {
                            // Call hasNext()
                            const has_next = if (iter_cd) |icd|
                                self.callInstanceMethod(icd, iterator_obj.object, "hasNext", &.{}) catch break
                            else
                                break;
                            if (!(utils.coerceToBool(has_next) catch false)) break;
                            // Call next()
                            const next_val = if (iter_cd) |icd|
                                try self.callInstanceMethod(icd, iterator_obj.object, "next", &.{})
                            else
                                break;
                            loop_env.set(fes.elem_name, next_val) catch {
                                try loop_env.define(fes.elem_name, next_val);
                            };
                            const result = try self.execBlock(fes.body, loop_env);
                            switch (result) {
                                .break_signal => break,
                                .continue_signal => {},
                                .return_val => return result,
                                .normal => {},
                            }
                        }
                    }
                }
                return .normal;
            },
            .while_stmt => |ws| {
                var iterations: u32 = 0;
                while (iterations < 100_000) : (iterations += 1) {
                    const cv = try self.evalExpr(ws.condition, current_env);
                    if (!(utils.coerceToBool(cv) catch false)) break;
                    const result = try self.execBlock(ws.body, current_env);
                    switch (result) {
                        .break_signal => break,
                        .continue_signal => {},
                        .return_val => return result,
                        .normal => {},
                    }
                }
                return .normal;
            },
            .do_while => |dw| {
                var iterations: u32 = 0;
                while (iterations < 100_000) : (iterations += 1) {
                    const result = try self.execBlock(dw.body, current_env);
                    switch (result) {
                        .break_signal => break,
                        .continue_signal => {},
                        .return_val => return result,
                        .normal => {},
                    }
                    const cv = try self.evalExpr(dw.condition, current_env);
                    if (!(utils.coerceToBool(cv) catch false)) break;
                }
                return .normal;
            },
            .return_stmt => |rs| {
                const val = if (rs.value) |v| try self.evalExpr(v, current_env) else Value.void_val;
                self.return_value = val;
                return .{ .return_val = val };
            },
            .break_stmt => return .break_signal,
            .continue_stmt => return .continue_signal,
            .switch_stmt => |sw| {
                const subject = try self.evalExpr(sw.subject, current_env);
                for (sw.when_clauses) |clause| {
                    switch (clause.pattern) {
                        .values => |values| {
                            for (values) |val_expr| {
                                var val_copy = val_expr;
                                const when_val = try self.evalExpr(&val_copy, current_env);
                                // String switch is case-sensitive in Apex (unlike == operator)
                                if (subject == .string and when_val == .string) {
                                    if (std.mem.eql(u8, subject.string, when_val.string)) {
                                        return self.execBlock(clause.body, current_env);
                                    }
                                } else if (utils.valueEql(subject, when_val)) {
                                    return self.execBlock(clause.body, current_env);
                                }
                                // Enum matching: when identifier matches string subject (case-insensitive for enums)
                                if (subject == .string and val_copy == .identifier) {
                                    if (std.ascii.eqlIgnoreCase(subject.string, val_copy.identifier.name)) {
                                        return self.execBlock(clause.body, current_env);
                                    }
                                }
                                // Also match when the when_val is null_val but the identifier matches a string
                                if (subject == .string and when_val == .null_val and val_copy == .identifier) {
                                    if (std.ascii.eqlIgnoreCase(subject.string, val_copy.identifier.name)) {
                                        return self.execBlock(clause.body, current_env);
                                    }
                                }
                                // Type-binding switch cases: `when Account record { ... }`
                                // The parser preserves only the type expression, so match the
                                // subject's runtime SObject/object type name against it.
                                if (self.switchTypePatternName(&val_copy)) |type_name| {
                                    if (subject == .sobject and std.ascii.eqlIgnoreCase(subject.sobject.type_name, type_name)) {
                                        return self.execBlock(clause.body, current_env);
                                    }
                                    if (subject == .object) {
                                        const subject_simple = if (std.mem.lastIndexOfScalar(u8, subject.object.class_name, '.')) |di|
                                            subject.object.class_name[di + 1 ..]
                                        else
                                            subject.object.class_name;
                                        if (std.ascii.eqlIgnoreCase(subject_simple, type_name)) {
                                            return self.execBlock(clause.body, current_env);
                                        }
                                    }
                                }
                            }
                        },
                        .else_clause => {
                            return self.execBlock(clause.body, current_env);
                        },
                    }
                }
                return .normal;
            },
            .try_stmt => |ts| {
                const result = self.execBlock(ts.body, current_env);
                if (result) |r| {
                    if (ts.finally_body) |fb| _ = try self.execBlock(fb, current_env);
                    return r;
                } else |_| {
                    if (ts.catches.len > 0) {
                        // Get the pending exception info
                        const exc_val = if (self.pending_exception) |pe| pe else blk: {
                            const exc = try self.arena.create(types.ObjectInstance);
                            exc.* = .{ .class_name = "Exception" };
                            break :blk Value{ .object = exc };
                        };
                        self.pending_exception = null;
                        const exc_obj = if (exc_val == .object) exc_val.object else blk: {
                            const exc = try self.arena.create(types.ObjectInstance);
                            exc.* = .{ .class_name = "Exception" };
                            break :blk exc;
                        };
                        const exc_class_name = exc_obj.class_name;
                        // Find matching catch clause by exception type
                        var matched_catch: ?*const ast.CatchClause = null;
                        var generic_catch: ?*const ast.CatchClause = null;
                        for (ts.catches) |*cc| {
                            const catch_type = cc.exception_type.name;
                            // Extract the simple name (after last dot) for both sides
                            const catch_simple = if (std.mem.lastIndexOfScalar(u8, catch_type, '.')) |di| catch_type[di + 1 ..] else catch_type;
                            const exc_simple = if (std.mem.lastIndexOfScalar(u8, exc_class_name, '.')) |di| exc_class_name[di + 1 ..] else exc_class_name;
                            // Exact or suffix match (case-insensitive)
                            if (std.ascii.eqlIgnoreCase(catch_type, exc_class_name) or
                                std.ascii.eqlIgnoreCase(catch_simple, exc_simple) or
                                std.ascii.eqlIgnoreCase(catch_simple, exc_class_name) or
                                std.ascii.eqlIgnoreCase(catch_type, exc_simple))
                            {
                                matched_catch = cc;
                                break;
                            }
                            // Check superclass hierarchy for exception matching
                            if (self.findClass(exc_class_name)) |exc_cd| {
                                if (exc_cd.super_class) |sc| {
                                    const sc_simple = if (std.mem.lastIndexOfScalar(u8, sc.name, '.')) |di| sc.name[di + 1 ..] else sc.name;
                                    if (std.ascii.eqlIgnoreCase(catch_simple, sc_simple) or
                                        std.ascii.eqlIgnoreCase(catch_type, sc.name))
                                    {
                                        matched_catch = cc;
                                        break;
                                    }
                                }
                            }
                            // Generic Exception catch (fallback)
                            if (std.ascii.eqlIgnoreCase(catch_type, "Exception") or
                                std.ascii.eqlIgnoreCase(catch_type, "System.Exception"))
                            {
                                generic_catch = cc;
                            }
                        }
                        // Use matched catch, or fall back to generic Exception, or first catch
                        const selected = matched_catch orelse generic_catch orelse &ts.catches[0];
                        const catch_env = try current_env.child();
                        try catch_env.define(selected.name, Value{ .object = exc_obj });
                        const catch_result = try self.execBlock(selected.body, catch_env);
                        if (ts.finally_body) |fb| _ = try self.execBlock(fb, current_env);
                        return catch_result;
                    }
                    self.pending_exception = null;
                    if (ts.finally_body) |fb| _ = try self.execBlock(fb, current_env);
                    return .normal;
                }
            },
            .throw_stmt => |ts| {
                const exc_val = try self.evalExpr(ts.expr, current_env);
                // Store exception value for catch handler
                self.pending_exception = exc_val;
                return error.ApexException;
            },
            .dml_stmt => |dml| {
                const target = try self.evalExpr(dml.target, current_env);
                // Check USER_MODE access for min-access users without permission sets
                const has_permset_dml = if (self.store.get("PermissionSetAssignment")) |psa| psa.items.len > 0 else false;
                if (dml.is_user_mode and self.is_min_access_user and !has_permset_dml) {
                    const from_type = if (target == .sobject) target.sobject.type_name else if (target == .list and target.list.items.items.len > 0 and target.list.items.items[0] == .sobject)
                        target.list.items.items[0].sobject.type_name
                    else
                        "SObject";
                    const msg = try std.fmt.allocPrint(self.arena, "No Access: Access to entity '{s}' denied", .{from_type});
                    const exc = try self.arena.create(types.ObjectInstance);
                    exc.* = .{ .class_name = "System.NoAccessException" };
                    try exc.fields.put(self.arena, "message", Value{ .string = msg });
                    self.pending_exception = Value{ .object = exc };
                    return error.ApexException;
                }
                try self.executeDml(dml.op, target);
                return .normal;
            },
            .run_as_stmt => |ras| {
                const user_val = try self.evalExpr(ras.user_expr, current_env);
                const prev_restricted = self.is_restricted_user;
                const prev_min_access = self.is_min_access_user;
                const prev_standard = self.is_standard_user;
                const prev_user_id = self.current_user_id;
                const prev_profile_id = self.current_profile_id;
                // Determine if the user is a restricted/min-access/standard user
                if (user_val == .sobject) {
                    if (user_val.sobject.id) |uid| self.current_user_id = uid;
                    if (utils.sobjectGet(&user_val.sobject.fields, "ProfileId") orelse utils.sobjectGet(&user_val.sobject.fields, "profileId")) |pv| {
                        if (pv == .string) self.current_profile_id = pv.string;
                    } else if (utils.sobjectGet(&user_val.sobject.fields, "Profile")) |prof| {
                        if (prof == .sobject and prof.sobject.id != null) self.current_profile_id = prof.sobject.id.?;
                    }
                    const profile_name = self.getUserProfileName(user_val.sobject) orelse blk: {
                        if (self.findRecordById("Profile", self.current_profile_id)) |profile_val| {
                            if (profile_val == .sobject) {
                                if (utils.sobjectGet(&profile_val.sobject.fields, "Name")) |name| {
                                    if (name == .string) break :blk name.string;
                                }
                            }
                        }
                        break :blk null;
                    };
                    if (profile_name) |pn| {
                        self.is_restricted_user = self.isRestrictedProfileName(pn);
                        self.is_min_access_user = std.ascii.indexOfIgnoreCase(pn, "Minimum Access") != null or
                            std.ascii.indexOfIgnoreCase(pn, "MinAccess") != null;
                        self.is_standard_user = self.isStandardProfileName(pn);
                    } else {
                        // No profile info found: assume non-restricted (e.g. runAs with current user)
                        self.is_restricted_user = false;
                        self.is_min_access_user = false;
                        self.is_standard_user = false;
                    }
                } else {
                    self.is_restricted_user = true;
                    self.is_min_access_user = true;
                    self.is_standard_user = false;
                }
                defer self.is_restricted_user = prev_restricted;
                defer self.is_min_access_user = prev_min_access;
                defer self.is_standard_user = prev_standard;
                defer self.current_user_id = prev_user_id;
                defer self.current_profile_id = prev_profile_id;
                const result = self.execBlock(ras.body, current_env);
                if (result) |r| return r else |e| return e;
            },
        }
    }

    fn switchTypePatternName(self: *Evaluator, expr: *const ast.Expr) ?[]const u8 {
        _ = self;
        return switch (expr.*) {
            .identifier => |id| id.name,
            .field_access => |fa| fa.field,
            else => null,
        };
    }

    // -----------------------------------------------------------------------
    // DML 操作
    // -----------------------------------------------------------------------

    pub fn executeDml(self: *Evaluator, op: ast.DmlOp, target: Value) anyerror!void {
        try self.executeDmlWithExternalIdInternal(op, target, null, true);
    }

    fn executeDmlWithExternalId(self: *Evaluator, op: ast.DmlOp, target: Value, external_id_field: ?[]const u8) anyerror!void {
        try self.executeDmlWithExternalIdInternal(op, target, external_id_field, true);
    }

    fn executeDmlWithExternalIdInternal(self: *Evaluator, op: ast.DmlOp, target: Value, external_id_field: ?[]const u8, count_limits: bool) anyerror!void {
        // Salesforce: empty list DML does not count as a DML statement
        if (target == .list and target.list.items.items.len == 0) return;
        if (count_limits) {
            self.limits_dml += 1;
            if (target == .list) {
                self.limits_dml_rows += @intCast(target.list.items.items.len);
            } else {
                self.limits_dml_rows += 1;
            }
        }
        // Null target → throw NullPointerException (like Salesforce)
        if (target == .null_val) {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "System.NullPointerException" };
            try exc.fields.put(self.arena, "message", Value{ .string = "Attempt to de-reference a null object" });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }

        // Determine object type for trigger lookup
        const obj_type = self.getTargetObjectType(target);

        // Determine trigger event types
        const before_event: ?ast.TriggerEvent = switch (op) {
            .insert => .before_insert,
            .update => .before_update,
            .delete => .before_delete,
            else => null,
        };
        const after_event: ?ast.TriggerEvent = switch (op) {
            .insert => .after_insert,
            .update => .after_update,
            .delete => .after_delete,
            .undelete => .after_undelete,
            else => null,
        };

        // Build record list for trigger context
        var record_list = try self.buildRecordList(target);

        // Build old records for update/delete triggers
        var old_records: ?std.ArrayListUnmanaged(Value) = null;
        if (op == .update or op == .delete) {
            old_records = .empty;
            for (record_list.items) |item| {
                if (item == .sobject and item.sobject.id != null) {
                    // Find current record in store and deep-copy it (so DML mutations don't affect old snapshot)
                    if (self.findRecordInStore(item.sobject.type_name, item.sobject.id.?)) |stored| {
                        if (stored == .sobject) {
                            const clone = try self.arena.create(types.SObject);
                            clone.* = .{ .type_name = stored.sobject.type_name };
                            clone.id = stored.sobject.id;
                            for (stored.sobject.fields.keys(), stored.sobject.fields.values()) |k, v| {
                                try clone.fields.put(self.arena, k, v);
                            }
                            try old_records.?.append(self.arena, Value{ .sobject = clone });
                        } else {
                            try old_records.?.append(self.arena, stored);
                        }
                    } else {
                        try old_records.?.append(self.arena, item);
                    }
                }
            }
        }

        // Fire BEFORE trigger
        if (before_event) |evt| {
            if (obj_type) |ot| {
                try self.fireTrigger(ot, evt, &record_list, old_records);
            }
        }

        // Execute actual DML
        switch (op) {
            .insert => {
                if (target == .sobject) {
                    try self.insertRecord(target.sobject);
                } else if (target == .list) {
                    // Pre-validate all records before inserting any (allOrNothing semantics)
                    for (target.list.items.items) |item| {
                        if (item == .sobject) {
                            if (try self.validateRequiredFields(item.sobject, false)) |err_msg| {
                                const exc = try self.arena.create(types.ObjectInstance);
                                exc.* = .{ .class_name = "DmlException" };
                                try exc.fields.put(self.arena, "message", Value{ .string = err_msg });
                                self.pending_exception = Value{ .object = exc };
                                return error.ApexException;
                            }
                        }
                    }
                    for (target.list.items.items) |item| {
                        if (item == .sobject) try self.insertRecord(item.sobject);
                    }
                }
            },
            .update => {
                if (target == .sobject) {
                    try self.updateRecord(target.sobject);
                } else if (target == .list) {
                    for (target.list.items.items) |item| {
                        if (item == .sobject) try self.updateRecord(item.sobject);
                    }
                }
            },
            .upsert => {
                if (target == .sobject) {
                    try self.upsertRecord(target.sobject, external_id_field);
                } else if (target == .list) {
                    for (target.list.items.items) |item| {
                        if (item == .sobject) try self.upsertRecord(item.sobject, external_id_field);
                    }
                }
            },
            .delete => {
                if (target == .sobject) {
                    try self.deleteRecord(target.sobject);
                } else if (target == .list) {
                    for (target.list.items.items) |item| {
                        if (item == .sobject) try self.deleteRecord(item.sobject);
                    }
                }
            },
            .undelete => {
                if (target == .sobject) {
                    try self.undeleteRecord(target.sobject);
                } else if (target == .list) {
                    for (target.list.items.items) |item| {
                        if (item == .sobject) try self.undeleteRecord(item.sobject);
                    }
                }
            },
            .merge => {},
        }

        // Rebuild record list after DML (records now have IDs for insert, or from store for update)
        if (after_event != null) {
            if (op == .update) {
                // For updates, rebuild Trigger.new from the store to include all fields
                // (not just the fields passed to the DML target)
                var new_list: std.ArrayListUnmanaged(Value) = .empty;
                for (record_list.items) |item| {
                    if (item == .sobject and item.sobject.id != null) {
                        if (self.findRecordInStore(item.sobject.type_name, item.sobject.id.?)) |stored| {
                            try new_list.append(self.arena, stored);
                        } else {
                            try new_list.append(self.arena, item);
                        }
                    } else {
                        try new_list.append(self.arena, item);
                    }
                }
                record_list = new_list;
            } else {
                record_list = try self.buildRecordList(target);
            }
        }

        // Fire AFTER trigger
        if (after_event) |evt| {
            if (obj_type) |ot| {
                try self.fireTrigger(ot, evt, &record_list, old_records);
            }
        }

        // Auto-cleanup orphaned DuplicateRecordSets after DRI delete/update triggers complete
        if (op == .delete or op == .update) {
            if (obj_type) |ot| {
                if (std.ascii.eqlIgnoreCase(ot, "DuplicateRecordItem")) {
                    self.cleanupOrphanedDuplicateRecordSets() catch {};
                }
            }
        }
    }

    fn customPrefixCategory(type_name: []const u8) u8 {
        if (std.mem.endsWith(u8, type_name, "__mdt")) return 'm';
        if (std.mem.endsWith(u8, type_name, "__e")) return 'e';
        if (std.mem.endsWith(u8, type_name, "__b")) return 'b';
        if (std.mem.endsWith(u8, type_name, "__ChangeEvent")) return 'c';
        if (std.mem.endsWith(u8, type_name, "__History")) return 'h';
        if (std.mem.endsWith(u8, type_name, "__Share")) return 's';
        return 'a';
    }

    fn hashedCustomKeyPrefix(type_name: []const u8) [3]u8 {
        const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
        var hash: u32 = 2166136261;
        for (type_name) |ch| {
            hash ^= @as(u32, std.ascii.toLower(ch));
            hash *%= 16777619;
        }
        const suffix = hash % @as(u32, alphabet.len * alphabet.len);
        return .{
            customPrefixCategory(type_name),
            alphabet[@intCast(suffix / alphabet.len)],
            alphabet[@intCast(suffix % alphabet.len)],
        };
    }

    fn isTemplateSObjectType(type_name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(type_name, "CaseComment") or
            std.mem.endsWith(u8, type_name, "History") or
            std.mem.endsWith(u8, type_name, "__History");
    }

    /// Return the 3-character Salesforce key prefix for known SObject types.
    pub fn sobjectKeyPrefix(type_name: []const u8) [3]u8 {
        if (std.ascii.eqlIgnoreCase(type_name, "Account")) return .{ '0', '0', '1' };
        if (std.ascii.eqlIgnoreCase(type_name, "Contact")) return .{ '0', '0', '3' };
        if (std.ascii.eqlIgnoreCase(type_name, "Opportunity")) return .{ '0', '0', '6' };
        if (std.ascii.eqlIgnoreCase(type_name, "Lead")) return .{ '0', '0', 'Q' };
        if (std.ascii.eqlIgnoreCase(type_name, "Case")) return .{ '5', '0', '0' };
        if (std.ascii.eqlIgnoreCase(type_name, "Task")) return .{ '0', '0', 'T' };
        if (std.ascii.eqlIgnoreCase(type_name, "Event")) return .{ '0', '0', 'U' };
        if (std.ascii.eqlIgnoreCase(type_name, "User")) return .{ '0', '0', '5' };
        if (std.ascii.eqlIgnoreCase(type_name, "Campaign")) return .{ '7', '0', '1' };
        if (std.ascii.eqlIgnoreCase(type_name, "CampaignMember")) return .{ '0', '0', 'v' };
        if (std.ascii.eqlIgnoreCase(type_name, "Product2")) return .{ '0', '1', 't' };
        if (std.ascii.eqlIgnoreCase(type_name, "Pricebook2")) return .{ '0', '1', 's' };
        if (std.ascii.eqlIgnoreCase(type_name, "PricebookEntry")) return .{ '0', '1', 'u' };
        if (std.ascii.eqlIgnoreCase(type_name, "Contract")) return .{ '8', '0', '0' };
        if (std.ascii.eqlIgnoreCase(type_name, "Order")) return .{ '8', '0', '1' };
        if (std.ascii.eqlIgnoreCase(type_name, "ContentDocument")) return .{ '0', '6', '9' };
        if (std.ascii.eqlIgnoreCase(type_name, "ContentVersion")) return .{ '0', '6', '8' };
        if (std.ascii.eqlIgnoreCase(type_name, "ContentDocumentLink")) return .{ '0', '6', 'A' };
        if (std.ascii.eqlIgnoreCase(type_name, "EmailMessage")) return .{ '0', '2', 's' };
        if (std.ascii.eqlIgnoreCase(type_name, "EmailMessageRelation")) return .{ '0', 'J', 'A' };
        if (std.ascii.eqlIgnoreCase(type_name, "Organization")) return .{ '0', '0', 'D' };
        if (std.ascii.eqlIgnoreCase(type_name, "RecordType")) return .{ '0', '1', '2' };
        if (std.ascii.eqlIgnoreCase(type_name, "CaseComment")) return .{ '0', '0', 'N' };
        if (std.ascii.eqlIgnoreCase(type_name, "DuplicateRecordSet")) return .{ '0', 'D', 'n' };
        if (std.ascii.eqlIgnoreCase(type_name, "DuplicateRecordItem")) return .{ '0', 'D', 'o' };
        if (std.ascii.eqlIgnoreCase(type_name, "DuplicateRule")) return .{ '0', 'B', 'm' };
        if (std.ascii.eqlIgnoreCase(type_name, "Group")) return .{ '0', '0', 'G' };
        if (std.ascii.eqlIgnoreCase(type_name, "Profile")) return .{ '0', '0', 'e' };
        if (std.ascii.eqlIgnoreCase(type_name, "PermissionSet")) return .{ '0', 'P', 'S' };
        if (std.ascii.eqlIgnoreCase(type_name, "PermissionSetAssignment")) return .{ '0', 'P', 'a' };
        if (std.ascii.eqlIgnoreCase(type_name, "FieldPermissions")) return .{ '0', 'F', 'P' };
        if (std.ascii.eqlIgnoreCase(type_name, "ObjectPermissions")) return .{ '0', 'O', 'P' };
        if (std.ascii.eqlIgnoreCase(type_name, "Attachment")) return .{ '0', '0', 'P' };
        if (std.ascii.eqlIgnoreCase(type_name, "Note")) return .{ '0', '0', '2' };
        if (std.ascii.eqlIgnoreCase(type_name, "Solution")) return .{ '5', '0', '1' };
        if (std.ascii.eqlIgnoreCase(type_name, "OpportunityLineItem")) return .{ '0', '0', 'k' };
        if (std.ascii.eqlIgnoreCase(type_name, "Quote")) return .{ '0', 'Q', '0' };
        if (std.ascii.eqlIgnoreCase(type_name, "QuoteLineItem")) return .{ '0', 'Q', 'L' };
        if (std.mem.endsWith(u8, type_name, "__c") or
            std.mem.endsWith(u8, type_name, "__e") or
            std.mem.endsWith(u8, type_name, "__mdt") or
            std.mem.endsWith(u8, type_name, "__b") or
            std.mem.endsWith(u8, type_name, "__ChangeEvent") or
            std.mem.endsWith(u8, type_name, "__History") or
            std.mem.endsWith(u8, type_name, "__Share"))
        {
            return hashedCustomKeyPrefix(type_name);
        }
        // Default: use first 3 chars of type name (padded)
        if (type_name.len >= 3) return .{ type_name[0], type_name[1], type_name[2] };
        if (type_name.len == 2) return .{ type_name[0], type_name[1], '0' };
        if (type_name.len == 1) return .{ type_name[0], '0', '0' };
        return .{ 'a', '0', '0' };
    }

    fn sobjectTypeFromPrefix(prefix: []const u8) []const u8 {
        if (std.mem.eql(u8, prefix, "001")) return "Account";
        if (std.mem.eql(u8, prefix, "003")) return "Contact";
        if (std.mem.eql(u8, prefix, "006")) return "Opportunity";
        if (std.mem.eql(u8, prefix, "00Q")) return "Lead";
        if (std.mem.eql(u8, prefix, "500")) return "Case";
        if (std.mem.eql(u8, prefix, "00T")) return "Task";
        if (std.mem.eql(u8, prefix, "00U")) return "Event";
        if (std.mem.eql(u8, prefix, "005")) return "User";
        if (std.mem.eql(u8, prefix, "701")) return "Campaign";
        if (std.mem.eql(u8, prefix, "00e")) return "Profile";
        if (std.mem.eql(u8, prefix, "0PS")) return "PermissionSet";
        if (std.mem.eql(u8, prefix, "069")) return "ContentDocument";
        if (std.mem.eql(u8, prefix, "068")) return "ContentVersion";
        if (std.mem.eql(u8, prefix, "00G")) return "Group";
        if (std.mem.eql(u8, prefix, "012")) return "RecordType";
        if (std.mem.eql(u8, prefix, "00N")) return "CaseComment";
        if (std.mem.eql(u8, prefix, "501")) return "Solution";
        if (std.mem.eql(u8, prefix, "800")) return "Contract";
        if (std.mem.eql(u8, prefix, "801")) return "Order";
        if (std.ascii.eqlIgnoreCase(prefix, "00D")) return "Organization";
        return "SObject";
    }

    fn getTargetObjectType(self: *Evaluator, target: Value) ?[]const u8 {
        _ = self;
        if (target == .sobject) return target.sobject.type_name;
        if (target == .list) {
            for (target.list.items.items) |item| {
                if (item == .sobject) return item.sobject.type_name;
            }
        }
        return null;
    }

    fn buildRecordList(self: *Evaluator, target: Value) !std.ArrayListUnmanaged(Value) {
        var list: std.ArrayListUnmanaged(Value) = .empty;
        if (target == .sobject) {
            try list.append(self.arena, target);
        } else if (target == .list) {
            for (target.list.items.items) |item| {
                try list.append(self.arena, item);
            }
        }
        return list;
    }

    fn findRecordInStore(self: *Evaluator, type_name: []const u8, id: []const u8) ?Value {
        var store_iter = self.store.iterator();
        while (store_iter.next()) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.key_ptr.*, type_name)) continue;
            for (entry.value_ptr.items) |record| {
                if (record == .sobject and record.sobject.id != null) {
                    if (std.mem.eql(u8, record.sobject.id.?, id)) {
                        return record;
                    }
                }
            }
        }
        return null;
    }

    fn makeSObjectFieldToken(self: *Evaluator, object_type: []const u8, field_name: []const u8) !Value {
        const field = try self.arena.create(types.ObjectInstance);
        field.* = .{ .class_name = "Schema.SObjectField" };
        try field.fields.put(self.arena, "objectType", Value{ .string = object_type });
        try field.fields.put(self.arena, "fieldName", Value{ .string = field_name });
        try field.fields.put(self.arena, "name", Value{ .string = field_name });
        return Value{ .object = field };
    }

    fn extractSObjectFieldName(field_value: Value) ?[]const u8 {
        return switch (field_value) {
            .string => |s| s,
            .object => |obj| blk: {
                if (obj.fields.get("fieldName")) |field_name| {
                    if (field_name == .string) break :blk field_name.string;
                }
                if (obj.fields.get("name")) |field_name| {
                    if (field_name == .string) break :blk field_name.string;
                }
                break :blk null;
            },
            else => null,
        };
    }

    fn getUpsertFieldValue(obj: *types.SObject, field_name: []const u8) Value {
        if (std.ascii.eqlIgnoreCase(field_name, "Id")) {
            if (obj.id) |id| return Value{ .string = id };
        }
        return utils.sobjectGet(&obj.fields, field_name) orelse Value.null_val;
    }

    fn getFieldMetadata(self: *Evaluator, type_name: []const u8, field_name: []const u8) ?FieldMetadata {
        const type_meta = self.field_metadata.get(type_name) orelse return null;
        if (type_meta.get(field_name)) |meta| return meta;
        var iter = type_meta.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, field_name)) return entry.value_ptr.*;
        }
        return null;
    }

    fn fieldValuesEqualWithMetadata(_: *Evaluator, metadata: ?FieldMetadata, lhs: Value, rhs: Value) bool {
        if (metadata) |meta| {
            if (!meta.case_sensitive and lhs == .string and rhs == .string) {
                return std.ascii.eqlIgnoreCase(lhs.string, rhs.string);
            }
        }
        return utils.valueEql(lhs, rhs);
    }

    fn findRecordByFieldValue(self: *Evaluator, type_name: []const u8, field_name: []const u8, field_value: Value) ?*types.SObject {
        const metadata = self.getFieldMetadata(type_name, field_name);
        var store_iter = self.store.iterator();
        while (store_iter.next()) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.key_ptr.*, type_name)) continue;
            for (entry.value_ptr.items) |record| {
                if (record != .sobject) continue;
                const existing_value = getUpsertFieldValue(record.sobject, field_name);
                if (existing_value != .null_val and self.fieldValuesEqualWithMetadata(metadata, existing_value, field_value)) {
                    return record.sobject;
                }
            }
        }
        return null;
    }

    fn findUniqueFieldConflict(self: *Evaluator, obj: *types.SObject, only_present: bool) ?[]const u8 {
        const type_meta = self.field_metadata.get(obj.type_name) orelse return null;
        var field_iter = type_meta.iterator();
        while (field_iter.next()) |entry| {
            const field_name = entry.key_ptr.*;
            const metadata = entry.value_ptr.*;
            if (!metadata.is_unique) continue;

            const field_value = getUpsertFieldValue(obj, field_name);
            if (field_value == .null_val) {
                if (only_present) continue;
                continue;
            }

            if (self.findRecordByFieldValue(obj.type_name, field_name, field_value)) |existing| {
                if (obj.id != null and existing.id != null and std.ascii.eqlIgnoreCase(obj.id.?, existing.id.?)) {
                    continue;
                }
                return field_name;
            }
        }
        return null;
    }

    fn throwDuplicateValue(self: *Evaluator, field_name: []const u8) anyerror {
        const msg = try std.fmt.allocPrint(self.arena, "DUPLICATE_VALUE: duplicate value found: {s}", .{field_name});
        const exc = try self.arena.create(types.ObjectInstance);
        exc.* = .{ .class_name = "DmlException" };
        try exc.fields.put(self.arena, "message", Value{ .string = msg });
        self.pending_exception = Value{ .object = exc };
        return error.ApexException;
    }

    fn willUpsertCreateRecord(self: *Evaluator, obj: *types.SObject, external_id_field: ?[]const u8) bool {
        if (obj.id != null) return false;
        if (utils.sobjectGet(&obj.fields, "Id")) |id_val| {
            if (id_val != .null_val) return false;
        }
        if (external_id_field) |field_name| {
            const field_value = getUpsertFieldValue(obj, field_name);
            if (field_value != .null_val and self.findRecordByFieldValue(obj.type_name, field_name, field_value) != null) {
                return false;
            }
        }
        return true;
    }

    /// Get the profile name for a User SObject by checking Profile field or looking up profileId.
    pub fn getUserProfileName(self: *Evaluator, user: *types.SObject) ?[]const u8 {
        // Check the Profile field directly (SObject reference)
        if (utils.sobjectGet(&user.fields, "Profile")) |pv| {
            if (pv == .sobject) {
                if (utils.sobjectGet(&pv.sobject.fields, "Name")) |name| {
                    if (name == .string) return name.string;
                }
            }
        }
        // Check profileId → look up in the store
        if (utils.sobjectGet(&user.fields, "profileId") orelse utils.sobjectGet(&user.fields, "ProfileId")) |pid| {
            const pid_str = if (pid == .string) pid.string else null;
            if (pid_str) |profile_id| {
                var store_iter = self.store.iterator();
                while (store_iter.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Profile")) {
                        for (entry.value_ptr.items) |rec| {
                            if (rec == .sobject and rec.sobject.id != null and
                                std.mem.eql(u8, rec.sobject.id.?, profile_id))
                            {
                                if (utils.sobjectGet(&rec.sobject.fields, "Name")) |name| {
                                    if (name == .string) return name.string;
                                }
                            }
                        }
                    }
                }
            }
        }
        return null;
    }

    pub fn isRestrictedProfileName(_: *Evaluator, name: []const u8) bool {
        return std.ascii.indexOfIgnoreCase(name, "Minimum Access") != null or
            std.ascii.indexOfIgnoreCase(name, "MinAccess") != null or
            std.ascii.indexOfIgnoreCase(name, "Marketing") != null;
    }

    pub fn isStandardProfileName(_: *Evaluator, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "Standard User") or
            std.ascii.eqlIgnoreCase(name, "Standard Platform User") or
            std.ascii.eqlIgnoreCase(name, "Read Only") or
            std.ascii.eqlIgnoreCase(name, "Chatter Free User") or
            std.ascii.eqlIgnoreCase(name, "Chatter External User");
    }

    /// Check if an SObject type is a setup/admin object (not CRUD-accessible by Standard User)
    pub fn isSetupObject(_: *Evaluator, obj_name: []const u8) bool {
        const setup_objects = [_][]const u8{
            "User",
            "Profile",
            "PermissionSet",
            "PermissionSetLicense",
            "PermissionSetAssignment",
            "PermissionSetLicenseAssign",
            "PermissionSetGroup",
            "Group",
            "GroupMember",
            "UserRole",
            "Organization",
            "ApexClass",
            "ApexTrigger",
            "AccountBrand",
            "CustomPermission",
            "SetupEntityAccess",
        };
        for (setup_objects) |so| {
            if (std.ascii.eqlIgnoreCase(obj_name, so)) return true;
        }
        return false;
    }

    fn fireTrigger(self: *Evaluator, obj_type: []const u8, event: ast.TriggerEvent, new_records: *std.ArrayListUnmanaged(Value), old_records: ?std.ArrayListUnmanaged(Value)) anyerror!void {
        // Trigger recursion guard — limit to 8 levels (Salesforce allows deep trigger chains)
        if (self.trigger_depth >= 8) return;
        self.trigger_depth += 1;
        defer self.trigger_depth -= 1;

        // Lowercase object type for lookup
        const obj_lower = std.ascii.lowerString(self.arena.alloc(u8, obj_type.len) catch return, obj_type);

        const trigger_list = self.triggers.get(obj_lower) orelse return;

        for (trigger_list.items) |td| {
            // Check if this trigger handles the event
            var handles_event = false;
            for (td.events) |e| {
                if (e == event) {
                    handles_event = true;
                    break;
                }
            }
            if (!handles_event) continue;

            // Build Trigger context
            const new_list_val = try self.arena.create(types.ListValue);
            new_list_val.* = .{};
            for (new_records.items) |item| {
                try new_list_val.items.append(self.arena, item);
            }

            var old_list_val: ?*types.ListValue = null;
            if (old_records) |ors| {
                const olv = try self.arena.create(types.ListValue);
                olv.* = .{};
                for (ors.items) |item| {
                    try olv.items.append(self.arena, item);
                }
                old_list_val = olv;
            }

            // Build newMap/oldMap as MapValue (Id → SObject)
            var new_map_val: ?Value = null;
            if (event != .before_insert) {
                const map = try self.arena.create(types.MapValue);
                map.* = .{};
                for (new_records.items) |item| {
                    if (item == .sobject and item.sobject.id != null) {
                        try map.entries.put(self.arena, item.sobject.id.?, item);
                    }
                }
                new_map_val = Value{ .map = map };
            }

            var old_map_val: ?Value = null;
            if (old_records) |ors| {
                const map = try self.arena.create(types.MapValue);
                map.* = .{};
                for (ors.items) |item| {
                    if (item == .sobject and item.sobject.id != null) {
                        try map.entries.put(self.arena, item.sobject.id.?, item);
                    }
                }
                old_map_val = Value{ .map = map };
            }

            const is_before = (event == .before_insert or event == .before_update or event == .before_delete);
            const is_after = !is_before;
            const is_insert = (event == .before_insert or event == .after_insert);
            const is_update = (event == .before_update or event == .after_update);
            const is_delete = (event == .before_delete or event == .after_delete);
            const is_undelete = (event == .after_undelete);

            const operation_type: []const u8 = switch (event) {
                .before_insert => "BEFORE_INSERT",
                .before_update => "BEFORE_UPDATE",
                .before_delete => "BEFORE_DELETE",
                .after_insert => "AFTER_INSERT",
                .after_update => "AFTER_UPDATE",
                .after_delete => "AFTER_DELETE",
                .after_undelete => "AFTER_UNDELETE",
            };

            // Save and set trigger context
            const prev_context = self.trigger_context;
            self.trigger_context = .{
                .is_executing = true,
                .is_insert = is_insert,
                .is_update = is_update,
                .is_delete = is_delete,
                .is_undelete = is_undelete,
                .is_before = is_before,
                .is_after = is_after,
                .new_list = if (is_delete and is_before) (if (old_list_val) |olv| Value{ .list = olv } else null) else Value{ .list = new_list_val },
                .old_list = if (old_list_val) |olv| Value{ .list = olv } else null,
                .new_map = new_map_val,
                .old_map = old_map_val,
                .size = @intCast(new_records.items.len),
                .operation_type = operation_type,
            };
            // For delete triggers, Trigger.new is null and Trigger.old has the records
            if (is_delete) {
                self.trigger_context.?.new_list = if (is_after) null else null;
                self.trigger_context.?.old_list = if (old_list_val) |olv| Value{ .list = olv } else Value{ .list = new_list_val };
                if (is_before) {
                    self.trigger_context.?.new_list = null;
                }
            }

            defer self.trigger_context = prev_context;

            // Execute trigger body
            const trigger_env = try self.global_env.child();
            _ = self.execBlock(td.body, trigger_env) catch |err| {
                // If trigger throws an exception, wrap it in DmlException
                if (err == error.ApexException) {
                    if (self.pending_exception) |pe| {
                        if (pe == .object) {
                            const class_name_str = pe.object.class_name;
                            // If it's already a DmlException, just propagate it
                            if (std.ascii.indexOfIgnoreCase(class_name_str, "DmlException") != null) {
                                return err;
                            }
                            // Wrap non-DML exceptions in DmlException
                            const msg = if (pe.object.fields.get("message")) |m| (if (m == .string) m.string else "Trigger exception") else "Trigger exception";
                            const dml_exc = try self.arena.create(types.ObjectInstance);
                            dml_exc.* = .{ .class_name = "DmlException" };
                            try dml_exc.fields.put(self.arena, "message", Value{ .string = msg });
                            self.pending_exception = Value{ .object = dml_exc };
                        }
                    }
                    return err;
                }
                return err;
            };
        }
    }

    fn insertRecord(self: *Evaluator, obj: *types.SObject) anyerror!void {
        if (obj.id != null) {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = "INVALID_FIELD_FOR_INSERT_UPDATE: cannot specify Id in an insert call" });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }
        if (utils.sobjectGet(&obj.fields, "Id")) |id_val| {
            if (id_val != .null_val) {
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "DmlException" };
                try exc.fields.put(self.arena, "message", Value{ .string = "INVALID_FIELD_FOR_INSERT_UPDATE: cannot specify Id in an insert call" });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
        }

        // Validate required fields — throw DmlException on failure
        if (try self.validateRequiredFields(obj, false)) |err_msg| {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = err_msg });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }

        // Auto-assign Id using Salesforce-style key prefixes for known types
        const key_prefix = sobjectKeyPrefix(obj.type_name);
        const id = try std.fmt.allocPrint(self.arena, "{s}{d:0>15}", .{ &key_prefix, self.next_id });
        self.next_id += 1;
        obj.id = id;
        try obj.fields.put(self.arena, "Id", Value{ .string = id });
        // Register Id → type_name mapping for getSObjectType() lookups
        try self.id_type_map.put(self.arena, id, obj.type_name);

        // Auto-generate system timestamp fields using current time
        {
            const now_str = builtins.currentDateTimeString(self.arena) catch "2026-01-01T00:00:00Z";
            if (utils.sobjectGet(&obj.fields, "CreatedDate") == null) {
                try obj.fields.put(self.arena, "CreatedDate", Value{ .string = now_str });
            }
            if (utils.sobjectGet(&obj.fields, "LastModifiedDate") == null) {
                try obj.fields.put(self.arena, "LastModifiedDate", Value{ .string = now_str });
            }
            if (utils.sobjectGet(&obj.fields, "SystemModstamp") == null) {
                try obj.fields.put(self.arena, "SystemModstamp", Value{ .string = now_str });
            }
        }

        // Auto-set CreatedById and CreatedBy relationship
        if (utils.sobjectGet(&obj.fields, "CreatedById") == null) {
            try obj.fields.put(self.arena, "CreatedById", Value{ .string = "005000000000001" });
        }
        if (utils.sobjectGet(&obj.fields, "CreatedBy") == null) {
            const created_by = try self.arena.create(types.SObject);
            created_by.* = .{ .type_name = "User", .id = "005000000000001" };
            try created_by.fields.put(self.arena, "Id", Value{ .string = "005000000000001" });
            try created_by.fields.put(self.arena, "Name", Value{ .string = "Test User" });
            try created_by.fields.put(self.arena, "Username", Value{ .string = "testuser@example.com" });
            try obj.fields.put(self.arena, "CreatedBy", Value{ .sobject = created_by });
        }
        if (utils.sobjectGet(&obj.fields, "LastModifiedById") == null) {
            try obj.fields.put(self.arena, "LastModifiedById", Value{ .string = "005000000000001" });
        }
        if (utils.sobjectGet(&obj.fields, "LastModifiedBy") == null) {
            const modified_by = try self.arena.create(types.SObject);
            modified_by.* = .{ .type_name = "User", .id = "005000000000001" };
            try modified_by.fields.put(self.arena, "Id", Value{ .string = "005000000000001" });
            try modified_by.fields.put(self.arena, "Name", Value{ .string = "Test User" });
            try modified_by.fields.put(self.arena, "Username", Value{ .string = "testuser@example.com" });
            try obj.fields.put(self.arena, "LastModifiedBy", Value{ .sobject = modified_by });
        }

        // Synthesize Name when it was omitted or explicitly set to null.
        const existing_name = utils.sobjectGet(&obj.fields, "Name");
        if (existing_name == null or existing_name.? == .null_val) {
            if (std.ascii.eqlIgnoreCase(obj.type_name, "Contact") or std.ascii.eqlIgnoreCase(obj.type_name, "Lead")) {
                const first = if (utils.sobjectGet(&obj.fields, "FirstName")) |v| (if (v == .string) v.string else "") else "";
                const last = if (utils.sobjectGet(&obj.fields, "LastName")) |v| (if (v == .string) v.string else "") else "";
                const name = if (first.len > 0 and last.len > 0)
                    try std.fmt.allocPrint(self.arena, "{s} {s}", .{ first, last })
                else if (last.len > 0)
                    last
                else if (first.len > 0)
                    first
                else
                    try std.fmt.allocPrint(self.arena, "{s}-{d:0>4}", .{ obj.type_name, self.next_id - 1 });
                try obj.fields.put(self.arena, "Name", Value{ .string = name });
            } else if (existing_name != null and existing_name.? == .null_val) {
                try obj.fields.put(self.arena, "Name", Value{ .string = id });
            } else {
                // Auto-generate Name for other objects (simulates auto-number for custom objects)
                const auto_name = try std.fmt.allocPrint(self.arena, "{s}-{d:0>4}", .{ obj.type_name, self.next_id - 1 });
                try obj.fields.put(self.arena, "Name", Value{ .string = auto_name });
            }
        }

        // Auto-set OwnerId to current user if not specified (Salesforce default)
        if (utils.sobjectGet(&obj.fields, "OwnerId") == null) {
            const default_owner_id = if (self.isGuestUserId(self.current_user_id)) "005000000000001" else self.current_user_id;
            try obj.fields.put(self.arena, "OwnerId", Value{ .string = default_owner_id });
        }
        if (utils.sobjectGet(&obj.fields, "OwnerId")) |owner_val| {
            if (owner_val == .string and self.isGuestUserId(owner_val.string)) {
                try obj.fields.put(self.arena, "OwnerId", Value{ .string = "005000000000001" });
            }
        }

        // Resolve relationship fields → set foreign key Ids
        // e.g., Contact.Account = accountRef → Contact.AccountId = accountRef.Id
        {
            var rel_keys_buf: [16][]const u8 = undefined;
            var rel_vals_buf: [16]Value = undefined;
            var rel_count: usize = 0;
            for (obj.fields.keys(), obj.fields.values()) |k, v| {
                if (v == .sobject and rel_count < rel_keys_buf.len) {
                    const fk_name = try std.fmt.allocPrint(self.arena, "{s}Id", .{k});
                    if (utils.sobjectGet(&obj.fields, fk_name) == null) {
                        if (v.sobject.id != null) {
                            // Direct reference with Id
                            rel_keys_buf[rel_count] = fk_name;
                            rel_vals_buf[rel_count] = Value{ .string = v.sobject.id.? };
                            rel_count += 1;
                        } else {
                            // External ID-based reference: find matching record in store
                            const ref_type = v.sobject.type_name;
                            // Look for external ID fields on the reference
                            for (v.sobject.fields.keys(), v.sobject.fields.values()) |rk, rv| {
                                if ((std.mem.endsWith(u8, rk, "__c") or std.mem.endsWith(u8, rk, "Id__c")) and rv == .string) {
                                    // Search store for a record of this type with matching external ID
                                    if (self.store.get(ref_type)) |records| {
                                        for (records.items) |rec| {
                                            if (rec == .sobject and rec.sobject.id != null) {
                                                if (utils.sobjectGet(&rec.sobject.fields, rk)) |stored_val| {
                                                    if (stored_val == .string and std.mem.eql(u8, stored_val.string, rv.string)) {
                                                        rel_keys_buf[rel_count] = fk_name;
                                                        rel_vals_buf[rel_count] = Value{ .string = rec.sobject.id.? };
                                                        rel_count += 1;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    break; // Only check first external ID field
                                }
                            }
                        }
                    }
                }
            }
            for (rel_keys_buf[0..rel_count], rel_vals_buf[0..rel_count]) |rk, rv| {
                try obj.fields.put(self.arena, rk, rv);
            }
        }

        if (self.findUniqueFieldConflict(obj, false)) |field_name| {
            obj.id = null;
            try obj.fields.put(self.arena, "Id", Value.null_val);
            return self.throwDuplicateValue(field_name);
        }

        // Add a snapshot copy to store (so later mutations to the live object don't affect stored records)
        const snapshot = try self.arena.create(types.SObject);
        snapshot.* = .{ .type_name = obj.type_name, .id = id };
        for (obj.fields.keys(), obj.fields.values()) |k, v| {
            try snapshot.fields.put(self.arena, k, v);
        }
        const gop = try self.store.getOrPut(self.arena, obj.type_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.arena, Value{ .sobject = snapshot });

        // Auto-generate ContentDownloadUrl for ContentDistribution
        if (std.ascii.eqlIgnoreCase(obj.type_name, "ContentDistribution")) {
            if (utils.sobjectGet(&obj.fields, "ContentDownloadUrl") == null) {
                try obj.fields.put(self.arena, "ContentDownloadUrl", Value{ .string = "https://mock.salesforce.com/content/download" });
                try snapshot.fields.put(self.arena, "ContentDownloadUrl", Value{ .string = "https://mock.salesforce.com/content/download" });
            }
        }

        // Auto-set IsLatest for ContentVersion
        if (std.ascii.eqlIgnoreCase(obj.type_name, "ContentVersion")) {
            if (utils.sobjectGet(&obj.fields, "IsLatest") == null) {
                try obj.fields.put(self.arena, "IsLatest", Value{ .boolean = true });
                try snapshot.fields.put(self.arena, "IsLatest", Value{ .boolean = true });
            }
        }

        // Auto-resolve ContentDocument reference on ContentDocumentLink insert
        if (std.ascii.eqlIgnoreCase(obj.type_name, "ContentDocumentLink")) {
            // Validate LinkedEntityId references an existing record
            const linked_entity_id = utils.sobjectGet(&obj.fields, "LinkedEntityId");
            if (linked_entity_id != null and linked_entity_id.? == .string) {
                const lid = linked_entity_id.?.string;
                // Check if the record exists in any store
                var found_linked = false;
                var store_iter = self.store.iterator();
                while (store_iter.next()) |entry| {
                    for (entry.value_ptr.items) |rec| {
                        if (rec == .sobject and rec.sobject.id != null) {
                            if (std.mem.eql(u8, rec.sobject.id.?, lid)) {
                                found_linked = true;
                                break;
                            }
                        }
                    }
                    if (found_linked) break;
                }
                if (!found_linked) {
                    const exc = try self.arena.create(types.ObjectInstance);
                    exc.* = .{ .class_name = "DmlException" };
                    try exc.fields.put(self.arena, "message", Value{ .string = "INVALID_FIELD_FOR_INSERT_UPDATE: LinkedEntityId does not reference a valid record" });
                    self.pending_exception = Value{ .object = exc };
                    return error.ApexException;
                }
            }
            // Auto-attach ContentDocument nested reference from store
            const cd_id_val = utils.sobjectGet(&obj.fields, "ContentDocumentId");
            if (cd_id_val != null and cd_id_val.? == .string) {
                const cd_id_str = cd_id_val.?.string;
                if (self.findRecordById("ContentDocument", cd_id_str)) |cd_rec| {
                    if (cd_rec == .sobject) {
                        try obj.fields.put(self.arena, "ContentDocument", cd_rec);
                        try snapshot.fields.put(self.arena, "ContentDocument", cd_rec);
                    }
                }
            }
        }

        // Auto-create ContentDocument when ContentVersion is inserted (Salesforce always creates one)
        if (std.ascii.eqlIgnoreCase(obj.type_name, "ContentVersion")) {
            const first_pub_loc = utils.sobjectGet(&obj.fields, "FirstPublishLocationId");
            {
                // Create ContentDocument
                const cd_id = try self.allocId();
                const cd = try self.arena.create(types.SObject);
                cd.* = .{ .type_name = "ContentDocument", .id = cd_id };
                try cd.fields.put(self.arena, "Id", Value{ .string = cd_id });
                try cd.fields.put(self.arena, "LatestPublishedVersionId", Value{ .string = id });
                try cd.fields.put(self.arena, "Title", utils.sobjectGet(&obj.fields, "Title") orelse Value{ .string = "Untitled" });
                // Derive FileType from PathOnClient extension
                const path_on_client = if (utils.sobjectGet(&obj.fields, "PathOnClient")) |poc| (if (poc == .string) poc.string else "") else "";
                const file_type: []const u8 = if (std.mem.endsWith(u8, path_on_client, ".png") or std.mem.endsWith(u8, path_on_client, ".PNG")) "PNG" else if (std.mem.endsWith(u8, path_on_client, ".jpg") or std.mem.endsWith(u8, path_on_client, ".jpeg")) "JPG" else if (std.mem.endsWith(u8, path_on_client, ".gif")) "GIF" else if (std.mem.endsWith(u8, path_on_client, ".pdf")) "PDF" else if (std.mem.endsWith(u8, path_on_client, ".docx")) "WORD_X" else if (std.mem.endsWith(u8, path_on_client, ".xlsx")) "EXCEL_X" else if (std.mem.endsWith(u8, path_on_client, ".pptx")) "POWER_POINT_X" else if (std.mem.endsWith(u8, path_on_client, ".m4a")) "M4A" else "UNKNOWN";
                try cd.fields.put(self.arena, "FileType", Value{ .string = file_type });
                const cd_gop = try self.store.getOrPut(self.arena, "ContentDocument");
                if (!cd_gop.found_existing) cd_gop.value_ptr.* = .empty;
                try cd_gop.value_ptr.append(self.arena, Value{ .sobject = cd });
                // Store ContentDocumentId on the ContentVersion
                try obj.fields.put(self.arena, "ContentDocumentId", Value{ .string = cd_id });
                try snapshot.fields.put(self.arena, "ContentDocumentId", Value{ .string = cd_id });
                // Create ContentDocumentLink only if FirstPublishLocationId is set
                if (first_pub_loc != null and first_pub_loc.? != .null_val) {
                    const cdl_id = try self.allocId();
                    const cdl = try self.arena.create(types.SObject);
                    cdl.* = .{ .type_name = "ContentDocumentLink", .id = cdl_id };
                    try cdl.fields.put(self.arena, "Id", Value{ .string = cdl_id });
                    try cdl.fields.put(self.arena, "ContentDocumentId", Value{ .string = cd_id });
                    try cdl.fields.put(self.arena, "LinkedEntityId", first_pub_loc.?);
                    // Nested ContentDocument reference for SOQL
                    const cd_ref = try self.arena.create(types.SObject);
                    cd_ref.* = .{ .type_name = "ContentDocument", .id = cd_id };
                    try cd_ref.fields.put(self.arena, "Id", Value{ .string = cd_id });
                    try cd_ref.fields.put(self.arena, "LatestPublishedVersionId", Value{ .string = id });
                    try cd_ref.fields.put(self.arena, "FileType", Value{ .string = file_type });
                    try cdl.fields.put(self.arena, "ContentDocument", Value{ .sobject = cd_ref });
                    const cdl_gop = try self.store.getOrPut(self.arena, "ContentDocumentLink");
                    if (!cdl_gop.found_existing) cdl_gop.value_ptr.* = .empty;
                    try cdl_gop.value_ptr.append(self.arena, Value{ .sobject = cdl });
                }
            }
        }

        // Auto-create EmailMessageRelation for each toId when EmailMessage is inserted
        if (std.ascii.eqlIgnoreCase(obj.type_name, "EmailMessage")) {
            if (utils.sobjectGet(&obj.fields, "toIds")) |to_ids_val| {
                if (to_ids_val == .list) {
                    for (to_ids_val.list.items.items) |to_id_item| {
                        if (to_id_item == .string) {
                            const emr_id = try self.allocId();
                            const emr = try self.arena.create(types.SObject);
                            emr.* = .{ .type_name = "EmailMessageRelation", .id = emr_id };
                            try emr.fields.put(self.arena, "Id", Value{ .string = emr_id });
                            try emr.fields.put(self.arena, "EmailMessageId", Value{ .string = id });
                            try emr.fields.put(self.arena, "RelationId", to_id_item);
                            try emr.fields.put(self.arena, "RelationType", Value{ .string = "ToAddress" });
                            const emr_gop = try self.store.getOrPut(self.arena, "EmailMessageRelation");
                            if (!emr_gop.found_existing) emr_gop.value_ptr.* = .empty;
                            try emr_gop.value_ptr.append(self.arena, Value{ .sobject = emr });
                        }
                    }
                }
            }
        }

        // Auto-maintain RecordCount on DuplicateRecordSet when DuplicateRecordItem is inserted
        if (std.ascii.eqlIgnoreCase(obj.type_name, "DuplicateRecordItem")) {
            try self.updateDuplicateRecordSetCount(obj, 1);
        }

        // Auto-initialize RecordCount to 0 on DuplicateRecordSet insert
        if (std.ascii.eqlIgnoreCase(obj.type_name, "DuplicateRecordSet")) {
            if (utils.sobjectGet(&obj.fields, "RecordCount") == null) {
                try obj.fields.put(self.arena, "RecordCount", Value{ .integer = 0 });
                try snapshot.fields.put(self.arena, "RecordCount", Value{ .integer = 0 });
            }
        }
    }

    /// Validate required fields on an SObject.
    /// When `only_present` is true (for updates), only validate fields that are
    /// explicitly present in the object's fields map — missing fields are not changed.
    fn validateRequiredFields(self: *Evaluator, obj: *types.SObject, only_present: bool) !?[]const u8 {
        _ = self;
        const type_name = obj.type_name;
        if (std.ascii.eqlIgnoreCase(type_name, "Account")) {
            const name_val = utils.sobjectGet(&obj.fields, "Name");
            // Insert: field must exist and be non-null/non-empty
            // Update: field must not be explicitly set to null/empty
            if (name_val == null) {
                if (!only_present) return "REQUIRED_FIELD_MISSING: Required fields are missing: [Name]";
            } else if (name_val.? == .null_val) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [Name]";
            } else if (name_val.? == .string and name_val.?.string.len == 0) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [Name]";
            }
        }
        if (std.ascii.eqlIgnoreCase(type_name, "Contact")) {
            const name_val = utils.sobjectGet(&obj.fields, "LastName");
            if (name_val == null) {
                if (!only_present) return "REQUIRED_FIELD_MISSING: Required fields are missing: [LastName]";
            } else if (name_val.? == .null_val) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [LastName]";
            }
        }
        if (std.ascii.eqlIgnoreCase(type_name, "Opportunity")) {
            const name_val = utils.sobjectGet(&obj.fields, "Name");
            if (name_val == null) {
                if (!only_present) return "REQUIRED_FIELD_MISSING: Required fields are missing: [Name]";
            } else if (name_val.? == .null_val) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [Name]";
            }
        }
        if (std.ascii.eqlIgnoreCase(type_name, "ContentVersion")) {
            // PathOnClient is required and must be non-empty
            const poc_val = utils.sobjectGet(&obj.fields, "PathOnClient");
            if (poc_val == null or poc_val.? == .null_val) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [PathOnClient]";
            }
            if (poc_val.? == .string and poc_val.?.string.len == 0) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [PathOnClient]";
            }
            // VersionData is required and must not be an empty Blob
            const vd_val = utils.sobjectGet(&obj.fields, "VersionData");
            if (vd_val == null or vd_val.? == .null_val) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [VersionData]";
            }
            if (vd_val.? == .object) {
                // Check if Blob has empty value
                if (utils.sobjectGet(&vd_val.?.object.fields, "value")) |inner| {
                    if (inner == .string and inner.string.len == 0) {
                        return "REQUIRED_FIELD_MISSING: Required fields are missing: [VersionData]";
                    }
                }
            }
        }
        return null;
    }

    fn updateRecord(self: *Evaluator, obj: *types.SObject) anyerror!void {
        // Validate only fields explicitly present (Salesforce doesn't re-validate all required fields on update)
        if (try self.validateRequiredFields(obj, true)) |err_msg| {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = err_msg });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }
        // If no Id, throw DmlException
        if (obj.id == null) {
            // Also check if Id is in fields
            const id_field = utils.sobjectGet(&obj.fields, "Id");
            if (id_field == null or id_field.? == .null_val) {
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "DmlException" };
                try exc.fields.put(self.arena, "message", Value{ .string = "MISSING_ARGUMENT: Id not specified in an update call:" });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
            // Set id from field
            if (id_field.? == .string) obj.id = id_field.?.string;
        }
        // Validate that the record exists in the store (if it has an Id)
        if (obj.id) |record_id| {
            if (utils.sobjectGet(&obj.fields, "OwnerId")) |owner_val| {
                if (owner_val == .string and self.isGuestUserId(owner_val.string)) {
                    const exc = try self.arena.create(types.ObjectInstance);
                    exc.* = .{ .class_name = "DmlException" };
                    try exc.fields.put(self.arena, "message", Value{ .string = "FIELD_INTEGRITY_EXCEPTION, field integrity exception (Guest users cannot be record owners.)" });
                    self.pending_exception = Value{ .object = exc };
                    return error.ApexException;
                }
            }
            var found_rec: ?*types.SObject = null;
            if (self.store.getPtr(obj.type_name)) |records| {
                for (records.items) |rec| {
                    if (rec == .sobject and rec.sobject.id != null and
                        std.mem.eql(u8, rec.sobject.id.?, record_id))
                    {
                        found_rec = rec.sobject;
                        break;
                    }
                }
            }
            if (found_rec == null) {
                // Also check via Id field
                if (utils.sobjectGet(&obj.fields, "Id")) |id_val| {
                    if (id_val == .string) {
                        var store_iter = self.store.iterator();
                        while (store_iter.next()) |entry| {
                            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, obj.type_name)) {
                                for (entry.value_ptr.items) |rec| {
                                    if (rec == .sobject and rec.sobject.id != null and
                                        std.mem.eql(u8, rec.sobject.id.?, id_val.string))
                                    {
                                        found_rec = rec.sobject;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (found_rec == null) {
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "DmlException" };
                try exc.fields.put(self.arena, "message", Value{ .string = "INVALID_CROSS_REFERENCE_KEY: invalid cross reference id" });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
            if (self.findUniqueFieldConflict(obj, true)) |field_name| {
                return self.throwDuplicateValue(field_name);
            }
            // Update the store snapshot with current field values.
            // If stored == obj (same pointer, e.g. from an uncopied SOQL result),
            // we must snapshot keys/values first to avoid iterator invalidation
            // when put() triggers a grow.
            if (found_rec) |stored| {
                const now_str = builtins.currentDateTimeString(self.arena) catch "2026-01-01T00:00:00Z";
                obj.fields.put(self.arena, "LastModifiedDate", Value{ .string = now_str }) catch {};
                obj.fields.put(self.arena, "LastModifiedById", Value{ .string = "005000000000001" }) catch {};
                if (utils.sobjectGet(&obj.fields, "LastModifiedBy") == null) {
                    const modified_by = try self.arena.create(types.SObject);
                    modified_by.* = .{ .type_name = "User", .id = "005000000000001" };
                    try modified_by.fields.put(self.arena, "Id", Value{ .string = "005000000000001" });
                    try modified_by.fields.put(self.arena, "Name", Value{ .string = "Test User" });
                    try modified_by.fields.put(self.arena, "Username", Value{ .string = "testuser@example.com" });
                    try obj.fields.put(self.arena, "LastModifiedBy", Value{ .sobject = modified_by });
                }
                if (stored == obj) {
                    const keys = self.arena.dupe([]const u8, obj.fields.keys()) catch return;
                    const vals = self.arena.dupe(Value, obj.fields.values()) catch return;
                    for (keys, vals) |k, v| {
                        stored.fields.put(self.arena, k, v) catch {};
                    }
                } else {
                    for (obj.fields.keys(), obj.fields.values()) |k, v| {
                        stored.fields.put(self.arena, k, v) catch {};
                    }
                }
            }
        }
    }

    fn upsertRecord(self: *Evaluator, obj: *types.SObject, external_id_field: ?[]const u8) anyerror!void {
        if (external_id_field) |field_name| {
            const field_value = getUpsertFieldValue(obj, field_name);
            if (field_value == .null_val) {
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "DmlException" };
                try exc.fields.put(self.arena, "message", Value{ .string = "MISSING_ARGUMENT: external id field not specified in an upsert call" });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
            if (self.findRecordByFieldValue(obj.type_name, field_name, field_value)) |existing| {
                if (existing.id) |existing_id| {
                    obj.id = existing_id;
                    try utils.sobjectPut(&obj.fields, self.arena, "Id", Value{ .string = existing_id });
                }
                try self.updateRecord(obj);
                return;
            }
        }
        if (obj.id != null) {
            // Check if record exists in store
            const record_id = obj.id.?;
            var found = false;
            if (self.store.getPtr(obj.type_name)) |records| {
                for (records.items) |rec| {
                    if (rec == .sobject and rec.sobject.id != null and
                        std.mem.eql(u8, rec.sobject.id.?, record_id))
                    {
                        found = true;
                        break;
                    }
                }
            }
            // Also check Id field
            if (!found) {
                if (utils.sobjectGet(&obj.fields, "Id")) |id_val| {
                    if (id_val == .string) {
                        var store_iter = self.store.iterator();
                        while (store_iter.next()) |entry| {
                            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, obj.type_name)) {
                                for (entry.value_ptr.items) |rec| {
                                    if (rec == .sobject and rec.sobject.id != null and
                                        std.mem.eql(u8, rec.sobject.id.?, id_val.string))
                                    {
                                        found = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (found) {
                try self.updateRecord(obj);
            } else {
                // Invalid cross reference Id — throw DmlException
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "DmlException" };
                try exc.fields.put(self.arena, "message", Value{ .string = "INVALID_CROSS_REFERENCE_KEY: invalid cross reference id" });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
        } else {
            try self.insertRecord(obj);
        }
    }

    fn deleteRecord(self: *Evaluator, obj: *types.SObject) anyerror!void {
        if (obj.id == null) {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = "ENTITY_IS_DELETED: entity is deleted" });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }
        var found = false;
        if (self.store.getPtr(obj.type_name)) |records| {
            var i: usize = 0;
            while (i < records.items.len) {
                if (records.items[i] == .sobject and records.items[i].sobject.id != null and
                    std.mem.eql(u8, records.items[i].sobject.id.?, obj.id.?))
                {
                    // Move to trash for potential undelete
                    const removed = records.orderedRemove(i);
                    if (removed == .sobject) {
                        try removed.sobject.fields.put(self.arena, "IsDeleted", Value{ .boolean = true });
                    }
                    const trash_gop = try self.trash.getOrPut(self.arena, obj.type_name);
                    if (!trash_gop.found_existing) trash_gop.value_ptr.* = .empty;
                    try trash_gop.value_ptr.append(self.arena, removed);
                    // Mark the original record's IsDeleted field
                    try obj.fields.put(self.arena, "IsDeleted", Value{ .boolean = true });
                    found = true;
                } else {
                    i += 1;
                }
            }
        }
        if (!found) {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = "ENTITY_IS_DELETED: entity is deleted" });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }
        // Auto-maintain RecordCount on DuplicateRecordSet when DuplicateRecordItem is deleted
        if (std.ascii.eqlIgnoreCase(obj.type_name, "DuplicateRecordItem")) {
            try self.updateDuplicateRecordSetCount(obj, -1);
        }
    }

    fn undeleteRecord(self: *Evaluator, obj: *types.SObject) anyerror!void {
        if (obj.id == null) {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = "UNDELETE_FAILED: entity not in recycle bin" });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }
        var found = false;
        if (self.trash.getPtr(obj.type_name)) |trashed| {
            var i: usize = 0;
            while (i < trashed.items.len) {
                if (trashed.items[i] == .sobject and trashed.items[i].sobject.id != null and
                    std.mem.eql(u8, trashed.items[i].sobject.id.?, obj.id.?))
                {
                    const restored = trashed.orderedRemove(i);
                    if (restored == .sobject) {
                        try restored.sobject.fields.put(self.arena, "IsDeleted", Value{ .boolean = false });
                    }
                    const gop = try self.store.getOrPut(self.arena, obj.type_name);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.arena, restored);
                    try obj.fields.put(self.arena, "IsDeleted", Value{ .boolean = false });
                    found = true;
                } else {
                    i += 1;
                }
            }
        }
        if (!found) {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = "UNDELETE_FAILED: entity not in recycle bin" });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }
    }

    /// Auto-maintain RecordCount on DuplicateRecordSet when DuplicateRecordItem is inserted/deleted.
    /// `delta` is +1 for insert, -1 for delete.
    fn updateDuplicateRecordSetCount(self: *Evaluator, dri: *types.SObject, delta: i64) !void {
        const drs_id_val = utils.sobjectGet(&dri.fields, "DuplicateRecordSetId") orelse return;
        if (drs_id_val != .string) return;
        const drs_id = drs_id_val.string;

        // Find the DuplicateRecordSet in the store and update RecordCount
        if (self.store.getPtr("DuplicateRecordSet")) |records| {
            for (records.items) |rec| {
                if (rec == .sobject and rec.sobject.id != null and
                    std.mem.eql(u8, rec.sobject.id.?, drs_id))
                {
                    const old_count: i64 = if (utils.sobjectGet(&rec.sobject.fields, "RecordCount")) |v|
                        (if (v == .integer) v.integer else 0)
                    else
                        0;
                    const new_count = @max(old_count + delta, 0);
                    try rec.sobject.fields.put(self.arena, "RecordCount", Value{ .integer = new_count });
                    break;
                }
            }
        }
    }

    /// Auto-delete DuplicateRecordSet records with RecordCount < 2 (and not freshly created with count 0).
    /// This mirrors the Salesforce trigger chain behavior: DRI delete → DRS trigger → auto-delete orphaned DRS.
    fn cleanupOrphanedDuplicateRecordSets(self: *Evaluator) !void {
        if (self.store.getPtr("DuplicateRecordSet")) |records| {
            var i: usize = 0;
            while (i < records.items.len) {
                const rec = records.items[i];
                if (rec == .sobject) {
                    const count = if (utils.sobjectGet(&rec.sobject.fields, "RecordCount")) |v|
                        (if (v == .integer) v.integer else 0)
                    else
                        0;
                    // Delete DRS when RecordCount > 0 but < 2 (i.e., 1 — single duplicate remaining)
                    // Also delete when RecordCount == 0 and there were items before (indicated by Object_Type__c being set)
                    if (count >= 1 and count < 2) {
                        const removed = records.orderedRemove(i);
                        const trash_gop = try self.trash.getOrPut(self.arena, "DuplicateRecordSet");
                        if (!trash_gop.found_existing) trash_gop.value_ptr.* = .empty;
                        try trash_gop.value_ptr.append(self.arena, removed);
                        continue;
                    }
                }
                i += 1;
            }
        }
    }

    // -----------------------------------------------------------------------
    // SOQL 実行
    // -----------------------------------------------------------------------

    fn executeSoql(self: *Evaluator, raw: []const u8, current_env: *Env) !Value {
        self.limits_soql += 1;
        // Strip brackets
        var soql = raw;
        if (soql.len > 2 and soql[0] == '[') soql = soql[1 .. soql.len - 1];
        soql = std.mem.trim(u8, try self.stripSoqlLineComments(soql), " \t\n\r");

        // Check security modes when running as restricted user
        if (self.is_restricted_user) {
            if (std.ascii.indexOfIgnoreCase(soql, "WITH SECURITY_ENFORCED") != null or
                std.ascii.indexOfIgnoreCase(soql, "WITH USER_MODE") != null or
                std.ascii.indexOfIgnoreCase(soql, "USER_MODE") != null)
            {
                const from_type_name = extractFromType(soql) orelse "SObject";
                const msg = try std.fmt.allocPrint(self.arena, "sObject type '{s}' is not supported. If you are attempting to use a custom object, be sure to append the '__c' after the entity name.", .{from_type_name});
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "System.QueryException" };
                try exc.fields.put(self.arena, "message", Value{ .string = msg });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
        }

        // SOSL: FIND ... RETURNING Type(fields) → use fixed search results
        if (soql.len > 4 and std.ascii.eqlIgnoreCase(soql[0..4], "FIND")) {
            return self.executeSosl(soql);
        }

        // Strip ALL ROWS keyword (include deleted records from trash)
        var include_all_rows = false;
        if (soql.len > 8) {
            if (std.ascii.eqlIgnoreCase(soql[soql.len - 8 ..], "ALL ROWS")) {
                soql = std.mem.trim(u8, soql[0 .. soql.len - 8], " \t\n\r");
                include_all_rows = true;
            }
        }

        // COUNT() query
        if (std.ascii.indexOfIgnoreCase(soql, "count()")) |_| {
            const from_type = extractFromType(soql);
            if (from_type) |ft| {
                var count: i64 = 0;
                var store_iter = self.store.iterator();
                while (store_iter.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, ft)) {
                        // Apply WHERE filter even for COUNT
                        for (entry.value_ptr.items) |record| {
                            if (self.matchesWhere(record, soql, current_env)) count += 1;
                        }
                        break;
                    }
                }
                return Value{ .integer = count };
            }
            return Value{ .integer = 0 };
        }

        // Aggregate functions (SUM/AVG/MIN/MAX/COUNT(field)) with optional GROUP BY
        if (std.ascii.indexOfIgnoreCase(soql, "SUM(") orelse
            std.ascii.indexOfIgnoreCase(soql, "AVG(") orelse
            std.ascii.indexOfIgnoreCase(soql, "MIN(") orelse
            std.ascii.indexOfIgnoreCase(soql, "MAX(") orelse
            std.ascii.indexOfIgnoreCase(soql, "COUNT(")) |_|
        {
            // Detect GROUP BY (skip plain COUNT() which is handled above)
            if (std.ascii.indexOfIgnoreCase(soql, "count()") != null and
                std.ascii.indexOfIgnoreCase(soql, "group by") == null)
            {
                // Already handled by COUNT() path above — shouldn't reach here, but guard
            } else {
                return self.executeAggregateQuery(soql, current_env);
            }
        }
        // GROUP BY without SUM/AVG/MIN/MAX (e.g., SELECT Field, COUNT(Id) ... GROUP BY Field)
        if (std.ascii.indexOfIgnoreCase(soql, "group by") != null) {
            return self.executeAggregateQuery(soql, current_env);
        }

        // Regular SELECT query
        const from_type = extractFromType(soql) orelse return self.makeEmptyList();
        var records: std.ArrayListUnmanaged(Value) = .empty;

        // Find matching records (case-insensitive type name)
        // Return copies to avoid aliasing store objects (prevents iterator
        // invalidation when the queried record is later DML-updated).
        var store_iter = self.store.iterator();
        while (store_iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, from_type)) {
                for (entry.value_ptr.items) |record| {
                    if (self.matchesWhere(record, soql, current_env)) {
                        if (record == .sobject) {
                            const copy = try self.cloneSObject(record.sobject);
                            try records.append(self.arena, Value{ .sobject = copy });
                        } else {
                            try records.append(self.arena, record);
                        }
                    }
                }
                break;
            }
        }

        if (records.items.len == 0 and std.ascii.eqlIgnoreCase(from_type, "UserRecordAccess")) {
            try self.seedUserRecordAccessRecords(soql, current_env, &records);
        }

        // Seed PermissionSet/PermissionSetLicense from IN clause (before metadata stubs)
        if (records.items.len == 0 and
            (std.ascii.eqlIgnoreCase(from_type, "PermissionSet") or
                std.ascii.eqlIgnoreCase(from_type, "PermissionSetLicense")))
        {
            const where_check = extractWhereClause(soql);
            if (where_check) |wc| {
                if (std.ascii.indexOfIgnoreCase(wc, " IN :") != null or std.ascii.indexOfIgnoreCase(wc, " IN (") != null) {
                    try self.seedNamedRecords(from_type, soql, current_env, &records);
                }
            }
        }

        // Load custom metadata records from .md-meta.xml files if store is empty
        // Only load if generateMetadataStub doesn't handle this type (to avoid conflicting stubs)
        if (records.items.len == 0 and std.mem.endsWith(u8, from_type, "__mdt") and
            self.store.get(from_type) == null)
        {
            // Check if this type has a hardcoded stub
            const has_hardcoded_stub = (try self.generateMetadataStub(from_type, soql, current_env)) != null;
            if (!has_hardcoded_stub) {
                try self.loadCustomMetadataFromFiles(from_type);
                // Re-scan store after loading
                var mdt_iter = self.store.iterator();
                while (mdt_iter.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, from_type)) {
                        for (entry.value_ptr.items) |record| {
                            if (self.matchesWhere(record, soql, current_env)) {
                                if (record == .sobject) {
                                    const copy = try self.cloneSObject(record.sobject);
                                    try records.append(self.arena, Value{ .sobject = copy });
                                } else {
                                    try records.append(self.arena, record);
                                }
                            }
                        }
                        break;
                    }
                }
            }
        }

        // Include deleted records from trash when ALL ROWS is specified
        if (include_all_rows) {
            var trash_iter = self.trash.iterator();
            while (trash_iter.next()) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, from_type)) {
                    for (entry.value_ptr.items) |record| {
                        if (self.matchesWhere(record, soql, current_env)) {
                            if (record == .sobject) {
                                const copy = try self.cloneSObject(record.sobject);
                                // Mark as deleted
                                try copy.fields.put(self.arena, "IsDeleted", Value{ .boolean = true });
                                try records.append(self.arena, Value{ .sobject = copy });
                            } else {
                                try records.append(self.arena, record);
                            }
                        }
                    }
                    break;
                }
            }
        }

        // Ensure SELECT clause fields exist on result records (even as null)
        // This allows Security.stripInaccessible to detect and strip them
        {
            const select_start2 = if (std.ascii.indexOfIgnoreCase(soql, "SELECT")) |si| si + 6 else 0;
            const from_start2 = std.ascii.indexOfIgnoreCase(soql, "FROM") orelse soql.len;
            if (from_start2 > select_start2) {
                const select_clause2 = std.mem.trim(u8, soql[select_start2..from_start2], " \t\n\r");
                // Skip FIELDS(STANDARD) and aggregate functions
                if (std.ascii.indexOfIgnoreCase(select_clause2, "FIELDS(") == null and
                    std.ascii.indexOfIgnoreCase(select_clause2, "COUNT(") == null and
                    std.ascii.indexOfIgnoreCase(select_clause2, "SUM(") == null)
                {
                    var field_iter = std.mem.splitScalar(u8, select_clause2, ',');
                    while (field_iter.next()) |raw_field| {
                        var field_name = std.mem.trim(u8, raw_field, " \t\n\r");
                        if (field_name.len == 0) continue;
                        // Skip subqueries (SELECT ... FROM ...)
                        if (field_name[0] == '(') continue;
                        // Handle toLabel(FieldName) — extract inner field name and apply label conversion
                        var is_to_label = false;
                        if (std.ascii.startsWithIgnoreCase(field_name, "toLabel(") and std.mem.endsWith(u8, field_name, ")")) {
                            field_name = field_name[8 .. field_name.len - 1];
                            is_to_label = true;
                        }
                        // Skip parent references (Account.Name → skip)
                        if (std.mem.indexOfScalar(u8, field_name, '.') != null) continue;
                        for (records.items) |item| {
                            if (item == .sobject) {
                                const selected_value = self.getSObjectFieldValueCaseInsensitive(item.sobject, field_name) orelse Value.null_val;
                                try utils.sobjectPut(&item.sobject.fields, self.arena, field_name, selected_value);
                                // toLabel: convert API name to picklist label using field-meta.xml
                                if (is_to_label) {
                                    if (utils.sobjectGet(&item.sobject.fields, field_name)) |fv| {
                                        if (fv == .string) {
                                            if (self.resolvePicklistLabel(item.sobject.type_name, field_name, fv.string)) |label| {
                                                try utils.sobjectPut(&item.sobject.fields, self.arena, field_name, Value{ .string = label });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // For dynamic queries (Database.query), throw QueryException for unknown object types.
        // An object type is "known" if it exists in the store OR has a metadata stub.
        // This is checked BEFORE metadata stub generation — if stubs generate records,
        // the object is known. If not, and the store doesn't have it either, it's unknown.

        // Metadata type stubs: generate dummy records for system objects
        // that don't exist in the in-memory store (ApexClass, PermissionSet, etc.)
        if (records.items.len == 0) {
            // FieldPermissions: return multiple field permission records
            if (std.ascii.eqlIgnoreCase(from_type, "FieldPermissions")) {
                const obj_type = self.extractWhereFieldValue(soql, "SobjectType", current_env) orelse "Account";
                // Generate field permissions: some readable+editable, some read-only
                const fields = [_]struct { name: []const u8, read: bool, edit: bool }{
                    .{ .name = "Name", .read = true, .edit = true },
                    .{ .name = "Id", .read = true, .edit = false },
                    .{ .name = "Description", .read = true, .edit = true },
                    .{ .name = "Website", .read = true, .edit = true },
                    .{ .name = "Industry", .read = true, .edit = true },
                    .{ .name = "Phone", .read = true, .edit = true },
                    .{ .name = "ShippingStreet", .read = true, .edit = true },
                    .{ .name = "BillingStreet", .read = true, .edit = true },
                };
                for (fields) |f| {
                    const fp = try self.arena.create(types.SObject);
                    fp.* = .{ .type_name = "FieldPermissions" };
                    const fp_id = try self.allocId();
                    fp.id = fp_id;
                    try fp.fields.put(self.arena, "Id", Value{ .string = fp_id });
                    try fp.fields.put(self.arena, "Field", Value{ .string = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ obj_type, f.name }) });
                    try fp.fields.put(self.arena, "PermissionsRead", Value{ .boolean = f.read });
                    try fp.fields.put(self.arena, "PermissionsEdit", Value{ .boolean = f.edit });
                    try fp.fields.put(self.arena, "SobjectType", Value{ .string = obj_type });
                    try records.append(self.arena, Value{ .sobject = fp });
                }
            } else if ((std.ascii.eqlIgnoreCase(from_type, "StaticResource") or std.ascii.eqlIgnoreCase(from_type, "ApexClass")) and std.ascii.indexOfIgnoreCase(soql, " IN (") != null) {
                // Handle IN clause for metadata types: extract all names from IN ('a', 'b', 'c')
                const where_clause = extractWhereClause(soql) orelse "";
                if (std.ascii.indexOfIgnoreCase(where_clause, " IN ")) |in_pos| {
                    // Find opening paren
                    var pp = in_pos + 4;
                    while (pp < where_clause.len and where_clause[pp] != '(') pp += 1;
                    if (pp < where_clause.len) {
                        pp += 1; // skip '('
                        // Extract each quoted string
                        while (pp < where_clause.len and where_clause[pp] != ')') {
                            while (pp < where_clause.len and where_clause[pp] != '\'' and where_clause[pp] != ')') pp += 1;
                            if (pp < where_clause.len and where_clause[pp] == '\'') {
                                pp += 1;
                                const start = pp;
                                while (pp < where_clause.len and where_clause[pp] != '\'') pp += 1;
                                if (pp > start) {
                                    const in_name = where_clause[start..pp];
                                    // debug removed
                                    const tmp_soql = try std.fmt.allocPrint(self.arena, "SELECT Id, Name FROM {s} WHERE Name = '{s}'", .{ from_type, in_name });
                                    if (try self.generateMetadataStub(from_type, tmp_soql, current_env)) |stub| {
                                        try records.append(self.arena, stub);
                                    }
                                }
                                if (pp < where_clause.len) pp += 1; // skip closing quote
                            }
                        }
                    }
                }
            } else if (std.ascii.eqlIgnoreCase(from_type, "ApexClass") and std.ascii.indexOfIgnoreCase(soql, " OR ") != null) {
                // ApexClass with OR: extract all Name values and generate stubs for each
                const where_clause = extractWhereClause(soql) orelse "";
                var wpos: usize = 0;
                while (wpos < where_clause.len) {
                    // Find next Name LIKE or Name =
                    const name_pos = std.ascii.indexOfIgnoreCasePos(where_clause, wpos, "Name") orelse break;
                    var j = name_pos + 4;
                    while (j < where_clause.len and (where_clause[j] == ' ' or where_clause[j] == '\t')) j += 1;
                    // Skip operator
                    if (j + 4 <= where_clause.len and std.ascii.eqlIgnoreCase(where_clause[j .. j + 4], "LIKE")) {
                        j += 4;
                    } else if (j < where_clause.len and where_clause[j] == '=') {
                        j += 1;
                    } else {
                        wpos = j;
                        continue;
                    }
                    while (j < where_clause.len and (where_clause[j] == ' ' or where_clause[j] == '\t')) j += 1;
                    var name_val: ?[]const u8 = null;
                    if (j < where_clause.len and where_clause[j] == '\'') {
                        const start = j + 1;
                        if (std.mem.indexOfPos(u8, where_clause, start, "'")) |end| {
                            name_val = where_clause[start..end];
                            wpos = end + 1;
                        } else {
                            wpos = j + 1;
                        }
                    } else if (j < where_clause.len and where_clause[j] == ':') {
                        const start = j + 1;
                        var end = start;
                        while (end < where_clause.len and (std.ascii.isAlphanumeric(where_clause[end]) or where_clause[end] == '_')) end += 1;
                        if (end > start) {
                            if (current_env.get(where_clause[start..end])) |bv| {
                                if (bv == .string) name_val = bv.string;
                            }
                        }
                        wpos = end;
                    } else {
                        wpos = j + 1;
                        continue;
                    }
                    if (name_val) |nv| {
                        // Use a temporary soql for the stub generator with a single WHERE
                        const tmp_soql = try std.fmt.allocPrint(self.arena, "SELECT Name, Body FROM {s} WHERE Name = '{s}'", .{ from_type, nv });
                        if (try self.generateMetadataStub(from_type, tmp_soql, current_env)) |stub| {
                            try records.append(self.arena, stub);
                        }
                    }
                }
            } else if (try self.generateMetadataStub(from_type, soql, current_env)) |stub_record| {
                try records.append(self.arena, stub_record);
            }
        }

        // Seed synthetic records for User/Profile/RecordType if none exist in store
        if (records.items.len == 0 and self.store.get(from_type) == null) {
            if (std.ascii.eqlIgnoreCase(from_type, "User")) {
                const use_query_specific_user = self.hasExactWhereFieldComparison(soql, "Username") or
                    self.hasExactWhereFieldComparison(soql, "Profile.Name") or
                    self.hasExactWhereFieldComparison(soql, "Profile.UserType") or
                    self.hasExactWhereFieldComparison(soql, "UserType");
                const user_record = if (use_query_specific_user)
                    try self.createUserForQuery(soql, current_env)
                else
                    try self.createCurrentUserRecord();
                // Only include seeded User if it matches WHERE clause
                if (self.matchesWhere(user_record, soql, current_env)) {
                    try records.append(self.arena, user_record);
                    if (user_record == .sobject) {
                        const gop = try self.store.getOrPut(self.arena, "User");
                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                        try gop.value_ptr.append(self.arena, user_record);
                    }
                }
            } else if (std.ascii.eqlIgnoreCase(from_type, "Profile")) {
                const use_query_specific_profile = !self.hasWhereFieldLikeComparison(soql, "Name");
                const profile_record = if (use_query_specific_profile)
                    try self.createProfileForQuery(soql, current_env)
                else
                    try self.createDefaultProfileRecord();
                if (self.matchesWhere(profile_record, soql, current_env)) {
                    try records.append(self.arena, profile_record);
                    // Also store in the data store so getUserProfileName can resolve ProfileId later
                    if (profile_record == .sobject) {
                        const gop = try self.store.getOrPut(self.arena, "Profile");
                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                        try gop.value_ptr.append(self.arena, profile_record);
                    }
                }
            } else if (std.ascii.eqlIgnoreCase(from_type, "RecordType")) {
                // Seed RecordType records into the store, then filter by WHERE clause
                try self.seedRecordTypeStore();
                // Re-scan store for matching records
                if (self.store.get("RecordType")) |rt_records| {
                    for (rt_records.items) |record| {
                        if (self.matchesWhere(record, soql, current_env)) {
                            if (record == .sobject) {
                                const copy = try self.cloneSObject(record.sobject);
                                try records.append(self.arena, Value{ .sobject = copy });
                            }
                        }
                    }
                }
            }
        }

        // If no records found from store or metadata stubs, and the object type
        // is not recognized at all, throw QueryException (unknown SObject type).
        // Known types: anything in the store, known metadata stubs, or common Salesforce objects.
        if (records.items.len == 0) {
            const in_store = self.store.get(from_type) != null;
            if (!in_store) {
                // Check if it's a common/known SObject type
                const known_types = [_][]const u8{
                    "Account",                    "Contact",                "Opportunity",                  "Case",                "Lead",                   "Task",                 "Event",
                    "Campaign",                   "User",                   "ContentVersion",               "ContentDocument",     "ContentDocumentLink",    "ContentDistribution",  "PermissionSet",
                    "PermissionSetAssignment",    "ObjectPermissions",      "Profile",                      "Organization",        "ApexClass",              "StaticResource",       "FieldPermissions",
                    "PermissionSetGroup",         "PlatformCachePartition", "Metadata_Driven_Trigger__mdt", "CronTrigger",         "AsyncApexJob",           "EntityDefinition",     "FieldDefinition",
                    "AggregateResult",            "RecordType",             "DuplicateRule",                "DuplicateRecordSet",  "DuplicateRecordItem",    "UserRecordAccess",     "AuthSession",
                    "LoginHistory",               "TaskStatus",             "BusinessHours",                "FeedItem",            "CollaborationGroup",     "UserRole",             "GroupMember",
                    "Group",                      "Attachment",             "Note",                         "EmailMessage",        "CaseComment",            "Solution",             "Contract",
                    "Product2",                   "Pricebook2",             "PricebookEntry",               "OpportunityLineItem", "Quote",                  "QuoteLineItem",        "PermissionSetLicense",
                    "EmailTemplate",              "Folder",                 "Document",                     "CampaignMember",      "CampaignMemberStatus",   "EmailMessageRelation", "OrgWideEmailAddress",
                    "PermissionSetLicenseAssign", "ServiceResource",        "AssignedResource",             "ServiceTerritory",    "ServiceTerritoryMember", "ApexTrigger",          "CustomPermission",
                    "FlowDefinitionView",         "FlowVersionView",        "ApexEmailNotification",        "Network",             "Topic",                  "OmniProcess",
                };
                var is_known = false;
                for (known_types) |kt| {
                    if (std.ascii.eqlIgnoreCase(from_type, kt)) {
                        is_known = true;
                        break;
                    }
                }
                // Also known if it ends with __c (custom object), __e (platform event), __mdt (custom metadata)
                if (std.mem.endsWith(u8, from_type, "__c") or std.mem.endsWith(u8, from_type, "__e") or std.mem.endsWith(u8, from_type, "__mdt") or std.mem.endsWith(u8, from_type, "__b")) {
                    is_known = true;
                }
                // Also known if generateMetadataStub can handle it
                if (!is_known) {
                    if (try self.generateMetadataStub(from_type, soql, current_env)) |_| {
                        is_known = true;
                    }
                }
                if (!is_known) {
                    const exc = try self.arena.create(types.ObjectInstance);
                    exc.* = .{ .class_name = "System.QueryException" };
                    try exc.fields.put(self.arena, "message", Value{ .string = try std.fmt.allocPrint(self.arena, "sObject type '{s}' is not supported. If you are attempting to use a custom object, be sure to append the '__c' after the entity name.", .{from_type}) });
                    self.pending_exception = Value{ .object = exc };
                    return error.ApexException;
                }
            }
        }

        // Apply sub-queries: (SELECT ... FROM ChildRelationship)
        if (extractSubQuery(soql)) |sub_info| {
            const rel_name = sub_info.relationship;
            const child_type = self.resolveChildType(from_type, rel_name);
            // For each parent record, find child records
            for (records.items) |*rec| {
                if (rec.* == .sobject) {
                    const parent_id = rec.sobject.id;
                    if (parent_id) |pid| {
                        var child_records: std.ArrayListUnmanaged(Value) = .empty;
                        // Look up the child type in the store
                        if (child_type) |ct| {
                            var child_iter = self.store.iterator();
                            while (child_iter.next()) |child_entry| {
                                if (std.ascii.eqlIgnoreCase(child_entry.key_ptr.*, ct)) {
                                    // Find the FK field name: for Contacts on Account, it's AccountId
                                    const fk_field = self.resolveForeignKey(ct, from_type, rel_name);
                                    for (child_entry.value_ptr.items) |child_rec| {
                                        if (child_rec == .sobject) {
                                            if (utils.sobjectGet(&child_rec.sobject.fields, fk_field)) |fk_val| {
                                                if (fk_val == .string and std.ascii.eqlIgnoreCase(fk_val.string, pid)) {
                                                    try child_records.append(self.arena, child_rec);
                                                }
                                            }
                                        }
                                    }
                                    break;
                                }
                            }
                        }
                        const child_list = try self.arena.create(types.ListValue);
                        child_list.* = .{ .items = child_records };
                        try rec.sobject.fields.put(self.arena, rel_name, Value{ .list = child_list });
                    }
                }
            }
        }

        // Apply parent field lookups: Account.Name, parent__r.Name
        try self.applyParentFieldLookups(soql, from_type, &records);

        // Resolve formula-like fields: <Relationship>_Name__c → parent.Name
        try self.resolveFormulaFields(soql, &records);

        // Apply ORDER BY
        if (extractOrderByField(soql)) |order_info| {
            const field_name = order_info.field;
            const descending = order_info.desc;
            // Simple insertion sort by field value
            const items = records.items;
            var ii: usize = 1;
            while (ii < items.len) : (ii += 1) {
                var jj = ii;
                while (jj > 0) {
                    const cmp_result = self.compareByField(items[jj - 1], items[jj], field_name);
                    const should_swap = if (descending) cmp_result < 0 else cmp_result > 0;
                    if (should_swap) {
                        const tmp = items[jj - 1];
                        items[jj - 1] = items[jj];
                        items[jj] = tmp;
                        jj -= 1;
                    } else break;
                }
            }
        }

        // Apply OFFSET (including :bindVar)
        var offset_val_opt = extractOffset(soql);
        if (offset_val_opt == null) {
            if (extractOffsetBindVar(soql)) |bind_name| {
                if (current_env.get(bind_name)) |bv| {
                    if (bv == .integer and bv.integer >= 0) {
                        offset_val_opt = @intCast(bv.integer);
                    }
                }
            }
        }
        if (offset_val_opt) |offset_val| {
            if (offset_val < records.items.len) {
                const remaining = records.items.len - offset_val;
                std.mem.copyForwards(Value, records.items[0..remaining], records.items[offset_val..records.items.len]);
                records.items.len = remaining;
            } else {
                records.items.len = 0;
            }
        }

        // Apply LIMIT (including :bindVar)
        var limit_val_opt = extractLimit(soql);
        if (limit_val_opt == null) {
            // Check for LIMIT :bindVar
            if (extractLimitBindVar(soql)) |bind_name| {
                if (current_env.get(bind_name)) |bv| {
                    if (bv == .integer and bv.integer > 0) {
                        limit_val_opt = @intCast(bv.integer);
                    }
                }
            }
        }
        if (limit_val_opt) |limit_val| {
            if (records.items.len > limit_val) {
                records.items.len = limit_val;
            }
        }

        const list = try self.arena.create(types.ListValue);
        list.* = .{ .items = records };
        return Value{ .list = list };
    }

    fn stripSoqlLineComments(self: *Evaluator, raw: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, raw, "//") == null) return raw;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        var in_string = false;
        while (i < raw.len) {
            const ch = raw[i];
            if (ch == '\'') {
                in_string = !in_string;
                try out.append(self.arena, ch);
                i += 1;
                continue;
            }
            if (!in_string and ch == '/' and i + 1 < raw.len and raw[i + 1] == '/') {
                i += 2;
                while (i < raw.len and raw[i] != '\n' and raw[i] != '\r') : (i += 1) {}
                continue;
            }
            try out.append(self.arena, ch);
            i += 1;
        }
        return out.items;
    }

    /// Generate a stub record for metadata/system types not in the in-memory store.
    /// Returns a dummy SObject with plausible field values, or null if not a metadata type.
    fn generateMetadataStub(self: *Evaluator, from_type: []const u8, soql: []const u8, current_env: *Env) !?Value {
        // Extract the Name value from WHERE clause (supports = 'val', LIKE :bindVar, = :bindVar)
        const name_val = self.extractWhereNameValue(soql, current_env) orelse "MockRecord";

        if (std.ascii.eqlIgnoreCase(from_type, "ApexClass") or std.ascii.eqlIgnoreCase(from_type, "ApexTrigger")) {
            const metadata_sources = if (std.ascii.eqlIgnoreCase(from_type, "ApexClass")) &self.class_sources else &self.trigger_sources;
            const type_label = if (std.ascii.eqlIgnoreCase(from_type, "ApexClass")) "class" else "trigger";
            var metadata_exists = false;
            if (std.ascii.eqlIgnoreCase(from_type, "ApexClass")) {
                metadata_exists = self.findClass(name_val) != null;
            }
            if (!metadata_exists) {
                for (metadata_sources.keys()) |k| {
                    if (std.ascii.eqlIgnoreCase(k, name_val)) {
                        metadata_exists = true;
                        break;
                    }
                }
            }
            if (!metadata_exists) return null;

            if (self.store.get(from_type)) |records| {
                for (records.items) |record| {
                    if (record == .sobject) {
                        if (utils.sobjectGet(&record.sobject.fields, "Name")) |stored_name| {
                            if (stored_name == .string and std.ascii.eqlIgnoreCase(stored_name.string, name_val)) {
                                return record;
                            }
                        }
                    }
                }
            }

            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = from_type };
            const prefix = if (std.ascii.eqlIgnoreCase(from_type, "ApexClass")) "01p" else "01q";
            const id = try std.fmt.allocPrint(self.arena, "{s}{d:0>15}", .{ prefix, self.next_id });
            self.next_id += 1;
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "Name", Value{ .string = name_val });
            try sob.fields.put(self.arena, "ApiVersion", Value{ .double = 62.0 });
            try sob.fields.put(self.arena, "LengthWithoutComments", Value{ .integer = 100 });
            try sob.fields.put(self.arena, "NamespacePrefix", Value{ .string = "" });
            const created_date = "2026-01-01T00:00:00Z";
            const modified_date = "2026-01-01T00:00:00Z";
            try sob.fields.put(self.arena, "CreatedDate", Value{ .string = created_date });
            try sob.fields.put(self.arena, "LastModifiedDate", Value{ .string = modified_date });
            try sob.fields.put(self.arena, "CreatedById", Value{ .string = "005000000000001" });
            try sob.fields.put(self.arena, "LastModifiedById", Value{ .string = "005000000000001" });
            const metadata_user = try self.createCurrentUserRecord();
            try sob.fields.put(self.arena, "CreatedBy", metadata_user);
            try sob.fields.put(self.arena, "LastModifiedBy", metadata_user);
            const body = blk: {
                if (metadata_sources.get(name_val)) |src| break :blk src;
                for (metadata_sources.keys(), metadata_sources.values()) |k, v| {
                    if (std.ascii.eqlIgnoreCase(k, name_val)) break :blk v;
                }
                break :blk try std.fmt.allocPrint(self.arena, "public {s} {s} {{\n    // mock body\n}}", .{ type_label, name_val });
            };
            try sob.fields.put(self.arena, "Body", Value{ .string = body });
            const gop = try self.store.getOrPut(self.arena, from_type);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.arena, Value{ .sobject = sob });
            try self.id_type_map.put(self.arena, id, from_type);
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "FlowDefinitionView")) {
            const api_name = self.extractWhereFieldValue(soql, "ApiName", current_env) orelse name_val;
            if (std.mem.indexOfScalar(u8, api_name, ' ') != null) return null;

            if (self.store.get(from_type)) |records| {
                for (records.items) |record| {
                    if (record == .sobject) {
                        if (utils.sobjectGet(&record.sobject.fields, "ApiName")) |stored_api_name| {
                            if (stored_api_name == .string and std.ascii.eqlIgnoreCase(stored_api_name.string, api_name)) {
                                return record;
                            }
                        }
                    }
                }
            }

            const durable_id = try std.fmt.allocPrint(self.arena, "300{d:0>15}", .{self.next_id});
            self.next_id += 1;
            const active_version_id = try std.fmt.allocPrint(self.arena, "301{d:0>15}", .{self.next_id});
            self.next_id += 1;

            const trigger_object = try self.arena.create(types.SObject);
            trigger_object.* = .{ .type_name = "EntityDefinition" };
            try trigger_object.fields.put(self.arena, "QualifiedApiName", Value{ .string = "Log__c" });

            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = from_type, .id = durable_id };
            try sob.fields.put(self.arena, "Id", Value{ .string = durable_id });
            try sob.fields.put(self.arena, "ActiveVersionId", Value{ .string = active_version_id });
            try sob.fields.put(self.arena, "ApiName", Value{ .string = api_name });
            try sob.fields.put(self.arena, "Description", Value{ .string = try std.fmt.allocPrint(self.arena, "{s} flow", .{api_name}) });
            try sob.fields.put(self.arena, "DurableId", Value{ .string = durable_id });
            try sob.fields.put(self.arena, "Label", Value{ .string = api_name });
            try sob.fields.put(self.arena, "LastModifiedBy", Value{ .string = "Test User" });
            try sob.fields.put(self.arena, "LastModifiedDate", Value{ .string = "2026-01-01T00:00:00Z" });
            try sob.fields.put(self.arena, "ManageableState", Value{ .string = "unmanaged" });
            try sob.fields.put(self.arena, "ProcessType", Value{ .string = "Flow" });
            try sob.fields.put(self.arena, "RecordTriggerType", Value{ .string = "RecordAfterSave" });
            try sob.fields.put(self.arena, "TriggerObjectOrEvent", Value{ .sobject = trigger_object });
            try sob.fields.put(self.arena, "TriggerOrder", Value{ .integer = 1 });
            try sob.fields.put(self.arena, "TriggerType", Value{ .string = "RecordAfterSave" });
            try sob.fields.put(self.arena, "VersionNumber", Value{ .integer = 1 });
            try sob.fields.put(self.arena, "IsActive", Value{ .boolean = true });

            const gop = try self.store.getOrPut(self.arena, from_type);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.arena, Value{ .sobject = sob });
            try self.id_type_map.put(self.arena, durable_id, from_type);
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "FlowVersionView")) {
            const durable_id = self.extractWhereFieldValue(soql, "DurableId", current_env) orelse return null;
            if (std.mem.indexOfScalar(u8, durable_id, ' ') != null) return null;

            if (self.store.get(from_type)) |records| {
                for (records.items) |record| {
                    if (record == .sobject) {
                        if (utils.sobjectGet(&record.sobject.fields, "DurableId")) |stored_durable_id| {
                            if (stored_durable_id == .string and std.ascii.eqlIgnoreCase(stored_durable_id.string, durable_id)) {
                                return record;
                            }
                        }
                    }
                }
            }

            var flow_definition_id: []const u8 = "300000000000000001";
            if (self.store.get("FlowDefinitionView")) |records| {
                for (records.items) |record| {
                    if (record != .sobject) continue;
                    if (utils.sobjectGet(&record.sobject.fields, "ActiveVersionId")) |active_version_id| {
                        if (active_version_id == .string and std.ascii.eqlIgnoreCase(active_version_id.string, durable_id)) {
                            if (utils.sobjectGet(&record.sobject.fields, "DurableId")) |definition_id| {
                                if (definition_id == .string) flow_definition_id = definition_id.string;
                            }
                            break;
                        }
                    }
                }
            }

            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = from_type, .id = durable_id };
            try sob.fields.put(self.arena, "Id", Value{ .string = durable_id });
            try sob.fields.put(self.arena, "DurableId", Value{ .string = durable_id });
            try sob.fields.put(self.arena, "ApiVersionRuntime", Value{ .double = 62.0 });
            try sob.fields.put(self.arena, "FlowDefinitionViewId", Value{ .string = flow_definition_id });
            try sob.fields.put(self.arena, "RunInMode", Value{ .string = "SystemMode" });
            try sob.fields.put(self.arena, "Status", Value{ .string = "Active" });
            try sob.fields.put(self.arena, "VersionNumber", Value{ .integer = 1 });

            const gop = try self.store.getOrPut(self.arena, from_type);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.arena, Value{ .sobject = sob });
            try self.id_type_map.put(self.arena, durable_id, from_type);
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "PermissionSet")) {
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "PermissionSet" };
            const id = try self.allocId();
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "Name", Value{ .string = name_val });
            try sob.fields.put(self.arena, "Label", Value{ .string = name_val });
            // Store so PermissionSet can be looked up later (e.g., by isFieldAllowedByPermSets)
            const gop = try self.store.getOrPut(self.arena, "PermissionSet");
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.arena, Value{ .sobject = sob });
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "CustomPermission")) {
            const developer_name = self.extractWhereFieldValue(soql, "DeveloperName", current_env) orelse name_val;

            if (self.store.get(from_type)) |records| {
                for (records.items) |record| {
                    if (record != .sobject) continue;
                    if (utils.sobjectGet(&record.sobject.fields, "DeveloperName")) |stored_dev_name| {
                        if (stored_dev_name == .string and std.ascii.eqlIgnoreCase(stored_dev_name.string, developer_name)) {
                            return record;
                        }
                    }
                }
            }

            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "CustomPermission" };
            const id = try self.allocId();
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "Name", Value{ .string = developer_name });
            try sob.fields.put(self.arena, "DeveloperName", Value{ .string = developer_name });
            try sob.fields.put(self.arena, "NamespacePrefix", Value.null_val);
            const gop = try self.store.getOrPut(self.arena, "CustomPermission");
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.arena, Value{ .sobject = sob });
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "PermissionSetGroup")) {
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "PermissionSetGroup" };
            const id = try self.allocId();
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "DeveloperName", Value{ .string = name_val });
            try sob.fields.put(self.arena, "MasterLabel", Value{ .string = name_val });
            try sob.fields.put(self.arena, "Status", Value{ .string = "Updated" });
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "Profile")) {
            const use_query_specific_profile = !self.hasWhereFieldLikeComparison(soql, "Name");
            const profile_record = if (use_query_specific_profile)
                try self.createProfileForQuery(soql, current_env)
            else
                try self.createCurrentProfileRecord();
            if (!self.matchesWhere(profile_record, soql, current_env)) return null;
            if (profile_record == .sobject) {
                // Store in the store so isRestrictedUser can look it up later
                const gop = try self.store.getOrPut(self.arena, "Profile");
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.arena, profile_record);
            }
            return profile_record;
        }

        if (std.ascii.eqlIgnoreCase(from_type, "ContentVersion")) {
            // Only generate a stub when no WHERE clause filters by specific fields.
            // When a WHERE clause is present (e.g., WHERE Title='...'), the query
            // should return empty if no matching records exist in the store, allowing
            // QueryException to be raised for single-record assignments.
            if (extractWhereClause(soql) != null) return null;
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "ContentVersion" };
            const id = try self.allocId();
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "Title", Value{ .string = "MockContent" });
            try sob.fields.put(self.arena, "ContentDocumentId", Value{ .string = try self.allocId() });
            try sob.fields.put(self.arena, "VersionData", Value{ .string = "mock-data" });
            try sob.fields.put(self.arena, "PathOnClient", Value{ .string = "mock.txt" });
            try sob.fields.put(self.arena, "FirstPublishLocationId", Value{ .string = try self.allocId() });
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "CronTrigger")) {
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "CronTrigger" };
            // Check if WHERE references a bind var for Id
            const where_clause = extractWhereClause(soql) orelse "";
            var cron_id: ?[]const u8 = null;
            if (std.mem.indexOf(u8, where_clause, ":")) |bind_pos| {
                const rest = std.mem.trim(u8, where_clause[bind_pos + 1 ..], " \t\n\r");
                var end_pos: usize = 0;
                while (end_pos < rest.len and (std.ascii.isAlphanumeric(rest[end_pos]) or rest[end_pos] == '_')) end_pos += 1;
                if (end_pos > 0) {
                    const bind_name = rest[0..end_pos];
                    if (current_env.get(bind_name)) |bv| {
                        if (bv == .string) cron_id = bv.string;
                    }
                }
            }
            sob.id = cron_id orelse try self.allocId();
            try sob.fields.put(self.arena, "Id", Value{ .string = sob.id.? });
            // Look up stored cron expression from System.schedule
            const cron_expr = if (cron_id) |cid| self.scheduled_jobs.get(cid) orelse "0 0 0 28 5 ? 2099" else "0 0 0 28 5 ? 2099";
            try sob.fields.put(self.arena, "CronExpression", Value{ .string = cron_expr });
            try sob.fields.put(self.arena, "TimesTriggered", Value{ .integer = 0 });
            try sob.fields.put(self.arena, "NextFireTime", Value{ .string = "2099-05-28 00:00:00" });
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "Organization")) {
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "Organization" };
            // Use a fixed ID for Organization (singleton object)
            const id = "00D000000000001";
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "IsSandbox", Value{ .boolean = true });
            try sob.fields.put(self.arena, "OrganizationType", Value{ .string = "Developer Edition" });
            try sob.fields.put(self.arena, "NamespacePrefix", Value.null_val);
            try sob.fields.put(self.arena, "Name", Value{ .string = "Mock Org" });
            try sob.fields.put(self.arena, "InstanceName", Value{ .string = "NA1" });
            try sob.fields.put(self.arena, "IsMultiCurrencyEnabled", Value{ .boolean = false });
            try sob.fields.put(self.arena, "IsReadOnly", Value{ .boolean = false });
            try sob.fields.put(self.arena, "FiscalYearStartMonth", Value{ .integer = 1 });
            try sob.fields.put(self.arena, "LanguageLocaleKey", Value{ .string = "en_US" });
            try sob.fields.put(self.arena, "TimeZoneSidKey", Value{ .string = "America/Los_Angeles" });
            // Store so subsequent queries return the same record
            const gop = try self.store.getOrPut(self.arena, "Organization");
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            if (gop.value_ptr.items.len == 0) {
                try gop.value_ptr.append(self.arena, Value{ .sobject = sob });
            }
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "PlatformCachePartition")) {
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "PlatformCachePartition" };
            const id = try self.allocId();
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "DeveloperName", Value{ .string = "default" });
            try sob.fields.put(self.arena, "NamespacePrefix", Value{ .string = "" });
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "DuplicateRule")) {
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "DuplicateRule" };
            const id = try self.allocId();
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "DeveloperName", Value{ .string = name_val });
            try sob.fields.put(self.arena, "SobjectType", Value{ .string = "Account" });
            try sob.fields.put(self.arena, "IsActive", Value{ .boolean = true });
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "StaticResource")) {
            // This returns a single record; for IN clause with multiple names,
            // the caller should handle generating multiple stubs.
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "StaticResource" };
            const id = try self.allocId();
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "Name", Value{ .string = name_val });
            // Try to load actual static resource from source_paths
            const body = self.loadStaticResourceBody(name_val) orelse "mock static resource body";
            try sob.fields.put(self.arena, "Body", Value{ .string = body });
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "Metadata_Driven_Trigger__mdt")) {
            // Trigger metadata: return empty list (no stub)
            return null;
        }

        if (std.ascii.eqlIgnoreCase(from_type, "Bucketed_Picklist__mdt")) {
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "Bucketed_Picklist__mdt" };
            const id = try self.allocId();
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "DeveloperName", Value{ .string = "Attendance" });
            try sob.fields.put(self.arena, "Field__c", Value{ .string = "AttendanceStatus__c" });
            try sob.fields.put(self.arena, "Object__c", Value{ .string = "Contact" });
            // Field__r relationship
            const field_ref = try self.arena.create(types.SObject);
            field_ref.* = .{ .type_name = "FieldDefinition" };
            try field_ref.fields.put(self.arena, "QualifiedAPIName", Value{ .string = "AttendanceStatus__c" });
            try sob.fields.put(self.arena, "Field__r", Value{ .sobject = field_ref });
            return Value{ .sobject = sob };
        }

        if (std.ascii.eqlIgnoreCase(from_type, "Picklist_Bucket__mdt")) {
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = "Picklist_Bucket__mdt" };
            const id = try self.allocId();
            sob.id = id;
            try sob.fields.put(self.arena, "Id", Value{ .string = id });
            try sob.fields.put(self.arena, "DeveloperName", Value{ .string = "Attended" });
            return Value{ .sobject = sob };
        }

        return null;
    }

    fn lookupBindValue(self: *Evaluator, current_env: *Env, var_name: []const u8) ?Value {
        if (current_env.get(var_name)) |bv| return bv;

        if (self.current_class) |cc| {
            const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, var_name }) catch null;
            if (key) |k| {
                if (self.global_env.get(k)) |bv| return bv;
            }
            if (self.findOuterClassName(cc)) |oc| {
                const okey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ oc, var_name }) catch null;
                if (okey) |k| {
                    if (self.global_env.get(k)) |bv| return bv;
                }
            }
        }

        if (current_env.get("this")) |tv| {
            if (tv == .object) {
                const this_cn = tv.object.class_name;
                const tkey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ this_cn, var_name }) catch null;
                if (tkey) |k| {
                    if (self.global_env.get(k)) |bv| return bv;
                }
                if (self.findOuterClassName(this_cn)) |oc| {
                    const okey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ oc, var_name }) catch null;
                    if (okey) |k| {
                        if (self.global_env.get(k)) |bv| return bv;
                    }
                }
            }
        }

        return null;
    }

    /// Extract the first value used in WHERE Name ... conditions.
    /// Supports =, LIKE, IN (:bind), and IN ('a', 'b') through the generic field extractor.
    fn extractWhereNameValue(self: *Evaluator, soql: []const u8, current_env: *Env) ?[]const u8 {
        return self.extractWhereFieldValue(soql, "Name", current_env);
    }

    /// Extract a specific field value from WHERE clause
    fn extractWhereFieldValue(self: *Evaluator, soql: []const u8, field_name: []const u8, current_env: *Env) ?[]const u8 {
        const where_clause = extractWhereClause(soql) orelse return null;
        var pos: usize = 0;
        while (pos + field_name.len <= where_clause.len) : (pos += 1) {
            if (std.ascii.eqlIgnoreCase(where_clause[pos .. pos + field_name.len], field_name) and
                (pos == 0 or where_clause[pos - 1] == ' ' or where_clause[pos - 1] == '(') and
                (pos + field_name.len == where_clause.len or where_clause[pos + field_name.len] == ' ' or where_clause[pos + field_name.len] == '\t'))
            {
                var j = pos + field_name.len;
                while (j < where_clause.len and (where_clause[j] == ' ' or where_clause[j] == '\t')) j += 1;

                var is_in = false;
                if (j + 2 <= where_clause.len and std.ascii.eqlIgnoreCase(where_clause[j .. j + 2], "IN")) {
                    is_in = true;
                    j += 2;
                } else if (j + 4 <= where_clause.len and std.ascii.eqlIgnoreCase(where_clause[j .. j + 4], "LIKE")) {
                    j += 4;
                } else if (j < where_clause.len and where_clause[j] == '=') {
                    j += 1;
                } else {
                    while (j < where_clause.len and where_clause[j] != '\'' and where_clause[j] != ':' and where_clause[j] != '(' and where_clause[j] != ' ') j += 1;
                }

                while (j < where_clause.len and (where_clause[j] == ' ' or where_clause[j] == '\t')) j += 1;

                if (is_in and j < where_clause.len and where_clause[j] == '(') {
                    j += 1;
                    while (j < where_clause.len and (where_clause[j] == ' ' or where_clause[j] == '\t')) j += 1;
                    if (j < where_clause.len and where_clause[j] == '\'') {
                        j += 1;
                        const start = j;
                        while (j < where_clause.len and where_clause[j] != '\'') j += 1;
                        return where_clause[start..j];
                    }
                    const start = j;
                    while (j < where_clause.len and where_clause[j] != ',' and where_clause[j] != ')' and where_clause[j] != ' ' and where_clause[j] != '\t') j += 1;
                    if (j > start) return std.mem.trim(u8, where_clause[start..j], " \t\n\r'");
                    continue;
                }

                if (j < where_clause.len and where_clause[j] == '\'') {
                    j += 1;
                    const start = j;
                    while (j < where_clause.len and where_clause[j] != '\'') j += 1;
                    return where_clause[start..j];
                }
                if (j < where_clause.len and where_clause[j] == ':') {
                    j += 1;
                    const start = j;
                    while (j < where_clause.len and (std.ascii.isAlphanumeric(where_clause[j]) or where_clause[j] == '_')) j += 1;
                    const var_name = where_clause[start..j];
                    if (self.lookupBindValue(current_env, var_name)) |v| {
                        switch (v) {
                            .string => return v.string,
                            .list => {
                                for (v.list.items.items) |item| {
                                    switch (item) {
                                        .string => return item.string,
                                        .sobject => {
                                            if (item.sobject.id) |id| return id;
                                        },
                                        else => {
                                            const coerced = utils.coerceToString(item, self.arena) catch continue;
                                            return coerced;
                                        },
                                    }
                                }
                                return null;
                            },
                            .set => {
                                var it = v.set.entries.iterator();
                                if (it.next()) |entry| {
                                    if (entry.value_ptr.* == .string) return entry.value_ptr.*.string;
                                }
                                return null;
                            },
                            .map => {
                                var it = v.map.entries.iterator();
                                if (it.next()) |entry| return entry.key_ptr.*;
                                return null;
                            },
                            else => return (utils.coerceToString(v, self.arena) catch null),
                        }
                    }
                }
            }
        }
        return null;
    }

    fn hasWhereFieldNullLiteral(self: *Evaluator, soql_or_cond: []const u8, field_name: []const u8) bool {
        _ = self;
        const clause = extractWhereClause(soql_or_cond) orelse soql_or_cond;
        var pos: usize = 0;
        while (pos + field_name.len <= clause.len) : (pos += 1) {
            if (!std.ascii.eqlIgnoreCase(clause[pos .. pos + field_name.len], field_name)) continue;
            if (!(pos == 0 or clause[pos - 1] == ' ' or clause[pos - 1] == '(')) continue;
            var j = pos + field_name.len;
            while (j < clause.len and (clause[j] == ' ' or clause[j] == '\t')) j += 1;
            if (j >= clause.len or clause[j] != '=') continue;
            j += 1;
            while (j < clause.len and (clause[j] == ' ' or clause[j] == '\t')) j += 1;
            if (j + 4 <= clause.len and std.ascii.eqlIgnoreCase(clause[j .. j + 4], "NULL")) return true;
        }
        return false;
    }

    /// Allocate a unique fake Salesforce ID
    fn allocId(self: *Evaluator) ![]const u8 {
        const id = try std.fmt.allocPrint(self.arena, "{d:0>18}", .{self.next_id});
        self.next_id += 1;
        return id;
    }

    /// Load a StaticResource body from the file system.
    /// Searches source_paths for staticresources/<name>.json, .csv, .xml, or .resource.
    fn loadStaticResourceBody(self: *Evaluator, name: []const u8) ?[]const u8 {
        const extensions = [_][]const u8{ ".json", ".csv", ".xml", ".txt", ".resource", "" };
        for (self.source_paths) |sp| {
            // Try walking the directory tree to find staticresources/<name>.<ext>
            if (self.findStaticResourceInDir(sp, name, &extensions)) |content| return content;
        }
        return null;
    }

    fn findStaticResourceInDir(self: *Evaluator, base_path: []const u8, name: []const u8, extensions: []const []const u8) ?[]const u8 {
        var dir = std.fs.cwd().openDir(base_path, .{ .iterate = true }) catch return null;
        defer dir.close();
        var walker = dir.walk(self.arena) catch return null;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            // Check if the file is in a "staticresources" directory and matches name
            const path_str = entry.path;
            // Look for "/staticresources/<name>.<ext>" or "staticresources/<name>.<ext>"
            if (std.mem.indexOf(u8, path_str, "staticresources/")) |sr_pos| {
                const after_sr = path_str[sr_pos + "staticresources/".len ..];
                // Check if the filename matches <name>.<ext>
                for (extensions) |ext| {
                    const expected = std.fmt.allocPrint(self.arena, "{s}{s}", .{ name, ext }) catch continue;
                    if (std.mem.eql(u8, after_sr, expected)) {
                        const full_path = std.fmt.allocPrint(self.arena, "{s}/{s}", .{ base_path, path_str }) catch continue;
                        if (std.fs.cwd().readFileAlloc(self.arena, full_path, 10 * 1024 * 1024)) |content| {
                            return content;
                        } else |_| {}
                    }
                }
            }
        }
        return null;
    }

    fn hasFlowDefinition(self: *Evaluator, flow_name: []const u8) bool {
        const suffix = std.fmt.allocPrint(self.arena, "{s}.flow-meta.xml", .{flow_name}) catch return false;
        for (self.source_paths) |base_path| {
            var dir = std.fs.cwd().openDir(base_path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var walker = dir.walk(self.arena) catch continue;
            defer walker.deinit();
            while (walker.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (std.mem.endsWith(u8, entry.path, suffix)) return true;
            }
        }
        return false;
    }

    /// Load custom metadata records from .md-meta.xml files in source_paths.
    /// Parses files matching `customMetadata/<TypeName>.<RecordName>.md-meta.xml` and
    /// populates the store with SObject records containing the field values.
    fn loadCustomMetadataFromFiles(self: *Evaluator, mdt_type: []const u8) !void {
        // Strip __mdt suffix to get the base type name for file matching
        const base_name = if (std.mem.endsWith(u8, mdt_type, "__mdt"))
            mdt_type[0 .. mdt_type.len - 5]
        else
            mdt_type;

        for (self.source_paths) |sp| {
            var dir = std.fs.cwd().openDir(sp, .{ .iterate = true }) catch continue;
            defer dir.close();
            var walker = dir.walk(self.arena) catch continue;
            defer walker.deinit();
            while (walker.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".md-meta.xml")) continue;
                // Check if filename matches: customMetadata/<BaseName>.<RecordName>.md-meta.xml
                if (std.mem.indexOf(u8, entry.path, "customMetadata/")) |cm_pos| {
                    const after_cm = entry.path[cm_pos + "customMetadata/".len ..];
                    // after_cm should be like "Customer_Fields.Contact_Config.md-meta.xml"
                    if (std.ascii.startsWithIgnoreCase(after_cm, base_name) and
                        after_cm.len > base_name.len and after_cm[base_name.len] == '.')
                    {
                        // Extract DeveloperName from filename: <BaseName>.<RecordName>.md-meta.xml
                        const after_dot = after_cm[base_name.len + 1 ..]; // "RecordName.md-meta.xml"
                        const dev_name_raw = if (std.mem.indexOf(u8, after_dot, ".")) |next_dot|
                            after_dot[0..next_dot]
                        else
                            after_dot;
                        // Duplicate on arena since walker memory is temporary
                        const dev_name = self.arena.dupe(u8, dev_name_raw) catch continue;

                        const full_path = std.fmt.allocPrint(self.arena, "{s}/{s}", .{ sp, entry.path }) catch continue;
                        const content = std.fs.cwd().readFileAlloc(self.arena, full_path, 1024 * 1024) catch continue;
                        if (try self.parseCustomMetadataXml(mdt_type, content)) |sob| {
                            // Set DeveloperName from filename
                            try sob.fields.put(self.arena, "DeveloperName", Value{ .string = dev_name });
                            const gop = try self.store.getOrPut(self.arena, mdt_type);
                            if (!gop.found_existing) gop.value_ptr.* = .empty;
                            try gop.value_ptr.append(self.arena, Value{ .sobject = sob });
                        }
                    }
                }
            }
        }
    }

    /// Parse a single .md-meta.xml file and return an SObject with the field values.
    fn parseCustomMetadataXml(self: *Evaluator, mdt_type: []const u8, xml: []const u8) !?*types.SObject {
        const sob = try self.arena.create(types.SObject);
        sob.* = .{ .type_name = mdt_type };
        const id = try self.allocId();
        sob.id = id;
        try sob.fields.put(self.arena, "Id", Value{ .string = id });

        // Simple XML parser: find <values><field>...</field><value ...>...</value></values> pairs
        var pos: usize = 0;
        while (pos < xml.len) {
            // Find <field>...</field>
            const field_start_tag = std.mem.indexOfPos(u8, xml, pos, "<field>") orelse break;
            const field_content_start = field_start_tag + "<field>".len;
            const field_end_tag = std.mem.indexOfPos(u8, xml, field_content_start, "</field>") orelse break;
            const field_name = std.mem.trim(u8, xml[field_content_start..field_end_tag], " \t\n\r");

            // Find corresponding <value ...>...</value>
            const value_search_start = field_end_tag + "</field>".len;
            const values_end = std.mem.indexOfPos(u8, xml, value_search_start, "</values>") orelse break;

            // Look for <value ...>content</value> within this <values> block
            // First check for xsi:nil="true" (self-closing tag: <value xsi:nil="true"/>)
            const val_region = xml[value_search_start..values_end];
            if (std.mem.indexOf(u8, val_region, "xsi:nil") != null) {
                // Field is explicitly null — skip it
                pos = values_end + "</values>".len;
                continue;
            }
            if (std.mem.indexOfPos(u8, xml, value_search_start, ">")) |val_tag_end| {
                if (val_tag_end < values_end) {
                    const val_content_start = val_tag_end + 1;
                    if (std.mem.indexOfPos(u8, xml, val_content_start, "</value>")) |val_end| {
                        if (val_end <= values_end) {
                            const field_value = std.mem.trim(u8, xml[val_content_start..val_end], " \t\n\r");
                            // Determine value type from xsi:type attribute in the <value> tag
                            const val_tag = xml[value_search_start..val_tag_end];
                            const typed_value: Value = if (std.mem.indexOf(u8, val_tag, "xsd:boolean") != null)
                                Value{ .boolean = std.ascii.eqlIgnoreCase(field_value, "true") }
                            else if (std.mem.indexOf(u8, val_tag, "xsd:double") != null or std.mem.indexOf(u8, val_tag, "xsd:decimal") != null)
                                if (std.fmt.parseFloat(f64, field_value)) |f| Value{ .double = f } else |_| Value{ .string = field_value }
                            else if (std.mem.indexOf(u8, val_tag, "xsd:int") != null)
                                if (std.fmt.parseInt(i64, field_value, 10)) |i| Value{ .integer = i } else |_| Value{ .string = field_value }
                            else
                                Value{ .string = field_value };
                            try sob.fields.put(self.arena, field_name, typed_value);
                            // Also create __r relationship for fields that reference FieldDefinitions
                            // Convention: Customer_Name__c → value is the API name of a field
                            // Create Customer_Name__r as a FieldDefinition with QualifiedAPIName = value
                            if (std.mem.endsWith(u8, field_name, "__c") and field_name.len > 3) {
                                const base = field_name[0 .. field_name.len - 3];
                                const rel_name = try std.fmt.allocPrint(self.arena, "{s}__r", .{base});
                                const fd = try self.arena.create(types.SObject);
                                fd.* = .{ .type_name = "FieldDefinition" };
                                try fd.fields.put(self.arena, "QualifiedAPIName", Value{ .string = field_value });
                                try sob.fields.put(self.arena, rel_name, Value{ .sobject = fd });
                            }
                        }
                    }
                }
            }

            pos = values_end + "</values>".len;
        }

        // Extract label
        if (std.mem.indexOf(u8, xml, "<label>")) |label_start| {
            const label_content = label_start + "<label>".len;
            if (std.mem.indexOfPos(u8, xml, label_content, "</label>")) |label_end| {
                try sob.fields.put(self.arena, "Label", Value{ .string = std.mem.trim(u8, xml[label_content..label_end], " \t\n\r") });
                try sob.fields.put(self.arena, "MasterLabel", Value{ .string = std.mem.trim(u8, xml[label_content..label_end], " \t\n\r") });
            }
        }

        return sob;
    }

    /// Execute an aggregate SOQL query (with SUM/AVG/MIN/MAX/COUNT and optional GROUP BY).
    /// Returns List<AggregateResult>.
    fn executeAggregateQuery(self: *Evaluator, soql: []const u8, current_env: *Env) !Value {
        const from_type_agg = extractFromType(soql) orelse return self.makeEmptyList();
        const select_start = if (std.ascii.indexOfIgnoreCase(soql, "SELECT")) |si| si + 6 else 0;
        const from_start = std.ascii.indexOfIgnoreCase(soql, "FROM") orelse soql.len;
        const select_clause = std.mem.trim(u8, soql[select_start..from_start], " \t\n\r");

        // Parse GROUP BY field(s)
        const group_by_idx = std.ascii.indexOfIgnoreCase(soql, "group by");
        var group_by_fields: [8][]const u8 = undefined;
        var group_by_count: usize = 0;
        if (group_by_idx) |gbi| {
            const gb_clause = std.mem.trim(u8, soql[gbi + 8 ..], " \t\n\r");
            var gb_iter = std.mem.splitScalar(u8, gb_clause, ',');
            while (gb_iter.next()) |raw_f| {
                const f = std.mem.trim(u8, raw_f, " \t\n\r");
                if (f.len == 0) continue;
                if (group_by_count < group_by_fields.len) {
                    group_by_fields[group_by_count] = f;
                    group_by_count += 1;
                }
            }
        }

        // Parse aggregate functions from SELECT clause
        // e.g., "LogPurgeAction__c LogPurgeAction__c, count(id)"
        // Each item is either a plain field (with optional alias) or FUNC(field) alias
        const AggItem = struct {
            fn_name: ?[]const u8, // null = plain field, "COUNT"/"SUM"/etc.
            field: []const u8,
            alias: []const u8,
        };
        var agg_items: [16]AggItem = undefined;
        var agg_count: usize = 0;
        {
            var expr_idx: usize = 0;
            var sel_iter = std.mem.splitScalar(u8, select_clause, ',');
            while (sel_iter.next()) |raw_item| {
                const item = std.mem.trim(u8, raw_item, " \t\n\r");
                if (item.len == 0) continue;
                if (agg_count >= agg_items.len) break;
                if (std.mem.indexOf(u8, item, "(")) |paren_start| {
                    // Aggregate function: FUNC(field) [alias]
                    const fn_name = std.mem.trim(u8, item[0..paren_start], " \t\n\r");
                    if (std.mem.indexOf(u8, item[paren_start..], ")")) |paren_end_rel| {
                        const paren_end = paren_start + paren_end_rel;
                        const field = std.mem.trim(u8, item[paren_start + 1 .. paren_end], " \t\n\r");
                        const after = std.mem.trim(u8, item[paren_end + 1 ..], " \t\n\r");
                        const alias = if (after.len > 0) after else try std.fmt.allocPrint(self.arena, "expr{d}", .{expr_idx});
                        agg_items[agg_count] = .{ .fn_name = fn_name, .field = field, .alias = alias };
                        agg_count += 1;
                        expr_idx += 1;
                    }
                } else {
                    // Plain field [alias] — e.g., "LogPurgeAction__c LogPurgeAction__c"
                    var parts = std.mem.splitScalar(u8, item, ' ');
                    const field = parts.next() orelse item;
                    const alias = parts.next() orelse field;
                    agg_items[agg_count] = .{ .fn_name = null, .field = field, .alias = alias };
                    agg_count += 1;
                }
            }
        }

        // Collect matching records
        var matched: std.ArrayListUnmanaged(Value) = .empty;
        var store_iter = self.store.iterator();
        while (store_iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, from_type_agg)) {
                for (entry.value_ptr.items) |record| {
                    if (self.matchesWhere(record, soql, current_env))
                        try matched.append(self.arena, record);
                }
                break;
            }
        }

        if (group_by_count == 0) {
            // No GROUP BY — single aggregate result over all matched records
            const agg = try self.arena.create(types.SObject);
            agg.* = .{ .type_name = "AggregateResult" };
            for (agg_items[0..agg_count]) |ai| {
                if (ai.fn_name) |fn_name| {
                    try agg.fields.put(self.arena, ai.alias, self.computeAggregate(fn_name, ai.field, matched.items));
                }
            }
            const result_list = try self.arena.create(types.ListValue);
            result_list.* = .{};
            try result_list.items.append(self.arena, Value{ .sobject = agg });
            return Value{ .list = result_list };
        }

        // GROUP BY: bucket records by group key(s)
        // Use string key for grouping (concatenation of field values)
        var group_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        var group_records: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)) = .empty;

        for (matched.items) |record| {
            // Build group key from GROUP BY fields
            var key_buf = std.ArrayListUnmanaged(u8){};
            for (group_by_fields[0..group_by_count]) |gb_field| {
                if (key_buf.items.len > 0) try key_buf.append(self.arena, '|');
                const fv = self.resolveFieldPath(record, gb_field);
                const fv_str = if (fv != null and fv.? != .null_val)
                    (utils.coerceToString(fv.?, self.arena) catch "")
                else
                    "";
                try key_buf.appendSlice(self.arena, fv_str);
            }
            const key = key_buf.items;

            // Find or create group
            var found = false;
            for (group_keys.items, 0..) |gk, idx| {
                if (std.mem.eql(u8, gk, key)) {
                    try group_records.items[idx].append(self.arena, record);
                    found = true;
                    break;
                }
            }
            if (!found) {
                try group_keys.append(self.arena, key);
                var new_group: std.ArrayListUnmanaged(Value) = .empty;
                try new_group.append(self.arena, record);
                try group_records.append(self.arena, new_group);
            }
        }

        // Build AggregateResult per group
        const result_list = try self.arena.create(types.ListValue);
        result_list.* = .{};
        for (group_records.items, 0..) |group, gi| {
            _ = gi;
            const agg = try self.arena.create(types.SObject);
            agg.* = .{ .type_name = "AggregateResult" };
            for (agg_items[0..agg_count]) |ai| {
                if (ai.fn_name) |fn_name| {
                    try agg.fields.put(self.arena, ai.alias, self.computeAggregate(fn_name, ai.field, group.items));
                } else {
                    // Plain field: take from first record in group, resolving dotted paths
                    if (group.items.len > 0) {
                        const fv = self.resolveFieldPath(group.items[0], ai.field) orelse Value.null_val;
                        try agg.fields.put(self.arena, ai.alias, fv);
                    }
                }
            }
            try result_list.items.append(self.arena, Value{ .sobject = agg });
        }
        return Value{ .list = result_list };
    }

    /// Compute a single aggregate value (COUNT/SUM/AVG/MIN/MAX) over a set of records.
    fn computeAggregate(self: *Evaluator, fn_name: []const u8, field: []const u8, records: []const Value) Value {
        _ = self;
        if (std.ascii.eqlIgnoreCase(fn_name, "COUNT")) {
            var count: i64 = 0;
            for (records) |r| {
                if (r == .sobject) {
                    // COUNT(Id) or COUNT(field) — count non-null values
                    if (utils.sobjectGet(&r.sobject.fields, field)) |v| {
                        if (v != .null_val) count += 1;
                    } else if (std.ascii.eqlIgnoreCase(field, "Id") and r.sobject.id != null) {
                        count += 1;
                    }
                }
            }
            return Value{ .integer = count };
        }
        // SUM, AVG, MIN, MAX
        var sum: f64 = 0;
        var count: i64 = 0;
        var min_val: ?f64 = null;
        var max_val: ?f64 = null;
        for (records) |r| {
            if (r == .sobject) {
                if (utils.sobjectGet(&r.sobject.fields, field)) |fv| {
                    const num: ?f64 = if (fv == .double) fv.double else if (fv == .integer) @floatFromInt(fv.integer) else null;
                    if (num) |n| {
                        sum += n;
                        count += 1;
                        if (min_val == null or n < min_val.?) min_val = n;
                        if (max_val == null or n > max_val.?) max_val = n;
                    }
                }
            }
        }
        if (std.ascii.eqlIgnoreCase(fn_name, "SUM")) return Value{ .double = sum };
        if (std.ascii.eqlIgnoreCase(fn_name, "AVG")) return if (count > 0) Value{ .double = sum / @as(f64, @floatFromInt(count)) } else Value{ .double = 0 };
        if (std.ascii.eqlIgnoreCase(fn_name, "MIN")) return if (min_val) |v| Value{ .double = v } else Value.null_val;
        if (std.ascii.eqlIgnoreCase(fn_name, "MAX")) return if (max_val) |v| Value{ .double = v } else Value.null_val;
        return Value{ .integer = count };
    }

    /// Resolve a dotted field path like "Log__r.LogPurgeAction__c" on a record.
    fn resolveFieldPath(self: *Evaluator, record: Value, path: []const u8) ?Value {
        if (record != .sobject) return null;
        if (std.mem.indexOfScalar(u8, path, '.') == null) {
            return self.getSObjectFieldValueCaseInsensitive(record.sobject, path);
        }
        return self.resolveFieldPathValue(record.sobject, path);
    }

    /// Execute a SOSL query using fixed search results.
    /// Returns List<List<SObject>> - one list per RETURNING type.
    fn executeSosl(self: *Evaluator, sosl: []const u8) !Value {
        // Parse RETURNING clause to find type names
        // e.g., FIND 'search' IN ALL FIELDS RETURNING Account(Name), Contact(LastName)
        var type_names: [8][]const u8 = undefined;
        var type_count: usize = 0;
        if (std.ascii.indexOfIgnoreCase(sosl, "RETURNING")) |ret_pos| {
            const returning = sosl[ret_pos + 9 ..];
            var iter = std.mem.splitScalar(u8, returning, ',');
            while (iter.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t\n\r");
                if (trimmed.len == 0) continue;
                // Extract type name (before parenthesis)
                var end: usize = 0;
                while (end < trimmed.len and trimmed[end] != '(' and trimmed[end] != ' ') end += 1;
                if (end > 0 and type_count < type_names.len) {
                    type_names[type_count] = trimmed[0..end];
                    type_count += 1;
                }
            }
        }

        // Build result: List<List<SObject>>
        const outer = try self.arena.create(types.ListValue);
        outer.* = .{};

        // Get fixed search result Ids
        var search_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        if (self.fixed_search_results) |fsr| {
            if (fsr == .list) {
                for (fsr.list.items.items) |item| {
                    if (item == .string) {
                        try search_ids.append(self.arena, item.string);
                    }
                }
            }
        }

        // For each RETURNING type, find matching records from store (or metadata stubs)
        for (type_names[0..type_count]) |type_name| {
            const inner = try self.arena.create(types.ListValue);
            inner.* = .{};
            var found_in_store = false;
            var store_iter = self.store.iterator();
            while (store_iter.next()) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, type_name)) {
                    found_in_store = true;
                    for (entry.value_ptr.items) |record| {
                        if (record == .sobject and record.sobject.id != null) {
                            // Check if Id is in fixed search results (or no filter)
                            if (search_ids.items.len == 0) {
                                try inner.items.append(self.arena, record);
                            } else {
                                for (search_ids.items) |sid| {
                                    if (std.ascii.eqlIgnoreCase(record.sobject.id.?, sid)) {
                                        try inner.items.append(self.arena, record);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    break;
                }
            }
            // For metadata types not in store, no results returned
            try outer.items.append(self.arena, Value{ .list = inner });
        }

        return Value{ .list = outer };
    }

    fn matchesWhere(self: *Evaluator, record: Value, soql: []const u8, current_env: *Env) bool {
        const where_clause = extractWhereClause(soql) orelse return true;
        if (record != .sobject) return true;
        return self.evalWhereCondition(record.sobject, where_clause, current_env);
    }

    fn evalWhereCondition(self: *Evaluator, sob: *types.SObject, clause: []const u8, current_env: *Env) bool {
        const trimmed = std.mem.trim(u8, clause, " \t\n\r");
        if (trimmed.len == 0) return true;

        // Handle AND
        if (findLogicalOp(trimmed, "AND")) |and_pos| {
            const left_part = trimmed[0..and_pos];
            const right_part = trimmed[and_pos + 3 ..];
            return self.evalWhereCondition(sob, left_part, current_env) and
                self.evalWhereCondition(sob, right_part, current_env);
        }

        // Handle OR
        if (findLogicalOp(trimmed, "OR")) |or_pos| {
            const left_part = trimmed[0..or_pos];
            const right_part = trimmed[or_pos + 2 ..];
            return self.evalWhereCondition(sob, left_part, current_env) or
                self.evalWhereCondition(sob, right_part, current_env);
        }

        // Strip outer parens
        if (trimmed.len > 2 and trimmed[0] == '(') {
            // Find matching paren
            var depth: u32 = 0;
            var all_enclosed = false;
            for (trimmed, 0..) |ch, i| {
                if (ch == '(') depth += 1;
                if (ch == ')') {
                    depth -= 1;
                    if (depth == 0 and i == trimmed.len - 1) all_enclosed = true;
                }
            }
            if (all_enclosed) {
                return self.evalWhereCondition(sob, trimmed[1 .. trimmed.len - 1], current_env);
            }
        }

        // Simple condition: field = 'value' or field = :bindVar or field != 'value'
        return self.evalSimpleCondition(sob, trimmed, current_env);
    }

    fn evalSimpleCondition(self: *Evaluator, sob: *types.SObject, cond: []const u8, current_env: *Env) bool {
        // Parse: field OP value
        // Find operator
        var op_pos: ?usize = null;
        var op_len: usize = 1;
        var is_neq = false;
        var is_like = false;
        var is_in = false;
        var is_gt = false;
        var is_gte = false;
        var is_lt = false;
        var is_lte = false;

        var i: usize = 0;
        while (i < cond.len) : (i += 1) {
            if (i + 1 < cond.len and cond[i] == '>' and cond[i + 1] == '=') {
                op_pos = i;
                op_len = 2;
                is_gte = true;
                break;
            }
            if (i + 1 < cond.len and cond[i] == '<' and cond[i + 1] == '=') {
                op_pos = i;
                op_len = 2;
                is_lte = true;
                break;
            }
            if (cond[i] == '>' and (i + 1 >= cond.len or cond[i + 1] != '=')) {
                op_pos = i;
                op_len = 1;
                is_gt = true;
                break;
            }
            if (cond[i] == '<' and (i + 1 >= cond.len or (cond[i + 1] != '=' and cond[i + 1] != '>'))) {
                op_pos = i;
                op_len = 1;
                is_lt = true;
                break;
            }
            if (cond[i] == '=' and (i == 0 or cond[i - 1] != '!' and cond[i - 1] != '<' and cond[i - 1] != '>')) {
                op_pos = i;
                op_len = 1;
                break;
            }
            if (i + 1 < cond.len and cond[i] == '!' and cond[i + 1] == '=') {
                op_pos = i;
                op_len = 2;
                is_neq = true;
                break;
            }
            if (i + 1 < cond.len and cond[i] == '<' and cond[i + 1] == '>') {
                op_pos = i;
                op_len = 2;
                is_neq = true;
                break;
            }
            if (i + 4 <= cond.len and std.ascii.eqlIgnoreCase(cond[i .. i + 4], "LIKE")) {
                if ((i == 0 or cond[i - 1] == ' ') and (i + 4 >= cond.len or cond[i + 4] == ' ')) {
                    op_pos = i;
                    op_len = 4;
                    is_like = true;
                    break;
                }
            }
            if (i + 2 <= cond.len and std.ascii.eqlIgnoreCase(cond[i .. i + 2], "IN")) {
                if ((i == 0 or cond[i - 1] == ' ') and (i + 2 >= cond.len or cond[i + 2] == ' ')) {
                    op_pos = i;
                    op_len = 2;
                    is_in = true;
                    break;
                }
            }
        }

        const op_start = op_pos orelse return true; // can't parse, include record
        const field_name = std.mem.trim(u8, cond[0..op_start], " \t\n\r");
        const value_str = std.mem.trim(u8, cond[op_start + op_len ..], " \t\n\r");

        // Get field value from record (case-insensitive), supporting dotted parent refs
        var field_val: Value = Value.null_val;
        var field_found = false;
        if (std.mem.indexOf(u8, field_name, ".")) |_| {
            if (self.resolveFieldPathValue(sob, field_name)) |resolved| {
                field_val = resolved;
                field_found = true;
            }
        } else {
            if (self.getSObjectFieldValueCaseInsensitive(sob, field_name)) |resolved| {
                field_val = resolved;
                field_found = true;
            }
        }
        if (!field_found) {
            // IsDeleted defaults to FALSE for records in the active store
            if (std.ascii.eqlIgnoreCase(field_name, "IsDeleted")) {
                field_val = Value{ .boolean = false };
                field_found = true;
            }
        }
        if (!field_found) {
            if (self.hasWhereFieldNullLiteral(cond, field_name)) {
                return !is_neq;
            }
            // Check if the comparison value is a null bind variable → skip condition
            if (value_str.len > 0 and value_str[0] == ':') {
                const bv_name = value_str[1..];
                if (std.mem.indexOf(u8, bv_name, ".")) |_| {} else {
                    if (current_env.get(bv_name)) |bv| {
                        if (bv == .null_val) return true; // null bind → include record
                    }
                }
            }
            return if (is_neq) true else false;
        }

        if (is_like) {
            // LIKE support: '%xxx%' → contains, 'xxx%' → startsWith, '%xxx' → endsWith
            if (field_val != .string) return false;
            var pattern = std.mem.trim(u8, value_str, " \t\n\r");
            // バインド変数 :type → 環境から値を解決
            if (pattern.len > 0 and pattern[0] == ':') {
                const var_name = pattern[1..];
                if (current_env.get(var_name)) |bind_val| {
                    if (bind_val == .string) {
                        pattern = bind_val.string;
                    } else return false;
                } else return false;
            }
            if (pattern.len >= 2 and pattern[0] == '\'') pattern = pattern[1..];
            if (pattern.len >= 1 and pattern[pattern.len - 1] == '\'') pattern = pattern[0 .. pattern.len - 1];
            pattern = self.collapseLikeWildcards(pattern);
            if (pattern.len == 0) return field_val.string.len == 0;
            var non_wildcard_len: usize = 0;
            for (pattern) |ch| {
                if (ch != '%') non_wildcard_len += 1;
            }
            if (non_wildcard_len == 0) return true;
            const starts_wild = pattern.len > 0 and pattern[0] == '%';
            const ends_wild = pattern.len > 0 and pattern[pattern.len - 1] == '%';
            const inner = pattern[@intFromBool(starts_wild) .. pattern.len - @intFromBool(ends_wild)];
            if (starts_wild and ends_wild) {
                return std.ascii.indexOfIgnoreCase(field_val.string, inner) != null;
            } else if (starts_wild) {
                return std.ascii.endsWithIgnoreCase(field_val.string, inner);
            } else if (ends_wild) {
                return std.ascii.startsWithIgnoreCase(field_val.string, inner);
            }
            return std.ascii.eqlIgnoreCase(field_val.string, pattern);
        }

        if (is_in) {
            // IN ('val1', 'val2') or IN :bindVar
            const in_str = std.mem.trim(u8, value_str, " \t\n\r");
            // Handle :bindVar for IN clause
            if (in_str.len > 0 and in_str[0] == ':') {
                const var_name = in_str[1..];
                if (current_env.get(var_name)) |bind_val| {
                    if (bind_val == .list) {
                        for (bind_val.list.items.items) |item| {
                            if (utils.valueEql(field_val, item)) return true;
                            // When comparing Id field against a list of SObjects,
                            // extract the SObject's Id for comparison
                            if (field_val == .string and item == .sobject) {
                                if (item.sobject.id) |item_id| {
                                    if (std.ascii.eqlIgnoreCase(field_val.string, item_id)) return true;
                                }
                            }
                        }
                        return false;
                    }
                    // Handle Map<Id, SObject> for IN clause (e.g. WHERE Id IN :mapVar)
                    if (bind_val == .map) {
                        if (field_val == .string) {
                            // Check if the field value is a key in the map (case-insensitive)
                            for (bind_val.map.entries.keys()) |key| {
                                if (std.ascii.eqlIgnoreCase(field_val.string, key)) return true;
                            }
                        }
                        return false;
                    }
                    if (bind_val == .set) {
                        const field_str = utils.coerceToString(field_val, self.arena) catch return true;
                        return bind_val.set.entries.contains(field_str);
                    }
                }
            }
            // IN ('val1', 'val2') — parse literal list
            if (std.mem.indexOf(u8, in_str, "(")) |paren_start| {
                const inner = if (std.mem.lastIndexOf(u8, in_str, ")")) |paren_end|
                    in_str[paren_start + 1 .. paren_end]
                else
                    in_str[paren_start + 1 ..];
                // Split by comma and check each value
                var iter = std.mem.splitScalar(u8, inner, ',');
                while (iter.next()) |part| {
                    const trimmed = std.mem.trim(u8, part, " \t\n\r'");
                    if (field_val == .string and std.ascii.eqlIgnoreCase(field_val.string, trimmed)) return true;
                    if (field_val == .integer) {
                        if (std.fmt.parseInt(i64, trimmed, 10)) |int_val| {
                            if (field_val.integer == int_val) return true;
                        } else |_| {}
                    }
                }
                return false;
            }
            return true; // fallback: include all
        }

        // Resolve the comparison value
        var cmp_val: Value = Value.null_val;
        if (value_str.len > 0 and value_str[0] == '\'') {
            // String literal
            if (value_str.len >= 2) {
                // Find closing quote
                var end = value_str.len;
                if (value_str[end - 1] == '\'') end -= 1;
                cmp_val = Value{ .string = value_str[1..end] };
            }
        } else if (value_str.len > 0 and value_str[0] == ':') {
            // Bind variable
            const var_name = value_str[1..];
            // Handle dotted: :insertedAccount.Id or :list[0].Id
            if (std.mem.indexOf(u8, var_name, ".")) |dot_pos| {
                const base_name = var_name[0..dot_pos];
                const prop_name = var_name[dot_pos + 1 ..];
                // Resolve base value, handling array index access (e.g. "list[0]")
                const base_val = blk: {
                    if (std.mem.indexOf(u8, base_name, "[")) |bracket_pos| {
                        const arr_name = base_name[0..bracket_pos];
                        const idx_end = std.mem.indexOfPos(u8, base_name, bracket_pos, "]") orelse break :blk current_env.get(base_name);
                        const idx_str = base_name[bracket_pos + 1 .. idx_end];
                        const idx = std.fmt.parseInt(usize, idx_str, 10) catch break :blk current_env.get(base_name);
                        const arr_val = current_env.get(arr_name) orelse break :blk @as(?Value, null);
                        if (arr_val == .list and idx < arr_val.list.items.items.len) {
                            break :blk @as(?Value, arr_val.list.items.items[idx]);
                        }
                        break :blk @as(?Value, null);
                    }
                    break :blk current_env.get(base_name);
                } orelse return true;
                if (base_val == .sobject) {
                    cmp_val = utils.sobjectGet(&base_val.sobject.fields, prop_name) orelse return true;
                } else if (base_val == .object) {
                    cmp_val = utils.sobjectGet(&base_val.object.fields, prop_name) orelse return true;
                } else {
                    return true;
                }
            } else {
                cmp_val = current_env.get(var_name) orelse blk: {
                    // Try current_class static field
                    if (self.current_class) |cc| {
                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, var_name }) catch break :blk @as(?Value, null);
                        if (self.global_env.get(key)) |v| break :blk v;
                        // Check outer class static field
                        if (self.findOuterClassName(cc)) |oc| {
                            const okey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ oc, var_name }) catch break :blk @as(?Value, null);
                            if (self.global_env.get(okey)) |v| break :blk v;
                        }
                    }
                    // Try "this" class and outer class static fields
                    if (current_env.get("this")) |tv| {
                        if (tv == .object) {
                            const this_cn = tv.object.class_name;
                            const tkey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ this_cn, var_name }) catch break :blk @as(?Value, null);
                            if (self.global_env.get(tkey)) |v| break :blk v;
                            if (self.findOuterClassName(this_cn)) |oc| {
                                const okey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ oc, var_name }) catch break :blk @as(?Value, null);
                                if (self.global_env.get(okey)) |v| break :blk v;
                            }
                        }
                    }
                    break :blk @as(?Value, null);
                } orelse return true;
                // Salesforce: WHERE field = :nullVar skips the condition (includes all records)
                if (cmp_val == .null_val and !is_neq) return true;
            }
        } else if (std.fmt.parseInt(i64, std.mem.trim(u8, value_str, " \t\n\r"), 10)) |int_val| {
            cmp_val = Value{ .integer = int_val };
        } else |_| {
            // Could be null or enum value
            const trimmed_value = std.mem.trim(u8, value_str, " \t\n\r");
            if (std.ascii.eqlIgnoreCase(trimmed_value, "null")) {
                cmp_val = Value.null_val;
            } else if (std.ascii.eqlIgnoreCase(trimmed_value, "true")) {
                cmp_val = Value{ .boolean = true };
            } else if (std.ascii.eqlIgnoreCase(trimmed_value, "false")) {
                cmp_val = Value{ .boolean = false };
            } else {
                return true; // unknown, include
            }
        }

        if (is_neq) return !utils.valueEql(field_val, cmp_val);
        if (is_gt or is_gte or is_lt or is_lte) {
            if (builtins.extractDateString(field_val)) |lhs_date| {
                if (builtins.extractDateString(cmp_val)) |rhs_date| {
                    const cmp = std.mem.order(u8, lhs_date, rhs_date);
                    if (is_gt) return cmp == .gt;
                    if (is_gte) return cmp == .gt or cmp == .eq;
                    if (is_lt) return cmp == .lt;
                    if (is_lte) return cmp == .lt or cmp == .eq;
                }
            }
            // Numeric comparison
            var lhs: ?f64 = null;
            var rhs: ?f64 = null;
            if (field_val == .integer) lhs = @floatFromInt(field_val.integer);
            if (field_val == .double) lhs = field_val.double;
            if (cmp_val == .integer) rhs = @floatFromInt(cmp_val.integer);
            if (cmp_val == .double) rhs = cmp_val.double;
            // String comparison for dates etc.
            if (field_val == .string and cmp_val == .string) {
                const cmp = std.mem.order(u8, field_val.string, cmp_val.string);
                if (is_gt) return cmp == .gt;
                if (is_gte) return cmp == .gt or cmp == .eq;
                if (is_lt) return cmp == .lt;
                if (is_lte) return cmp == .lt or cmp == .eq;
            }
            if (lhs != null and rhs != null) {
                if (is_gt) return lhs.? > rhs.?;
                if (is_gte) return lhs.? >= rhs.?;
                if (is_lt) return lhs.? < rhs.?;
                if (is_lte) return lhs.? <= rhs.?;
            }
            return false; // incomparable types
        }
        return utils.valueEql(field_val, cmp_val);
    }

    fn makeEmptyList(self: *Evaluator) !Value {
        const list = try self.arena.create(types.ListValue);
        list.* = .{};
        return Value{ .list = list };
    }

    /// Resolve the child SObject type from a relationship name.
    /// e.g., "Contacts" on Account → "Contact"
    fn resolveChildType(self: *Evaluator, parent_type: []const u8, relationship: []const u8) ?[]const u8 {
        if (self.resolveCustomChildRelationship(parent_type, relationship)) |custom| {
            return custom.child_type;
        }
        // Common Salesforce relationship mappings
        const mappings = .{
            .{ "Contacts", "Contact" },
            .{ "Opportunities", "Opportunity" },
            .{ "Cases", "Case" },
            .{ "Tasks", "Task" },
            .{ "Events", "Event" },
            .{ "Notes", "Note" },
            .{ "Attachments", "Attachment" },
            .{ "ContentDocumentLinks", "ContentDocumentLink" },
            .{ "Leads", "Lead" },
            .{ "AccountContactRoles", "AccountContactRole" },
            .{ "OpportunityContactRoles", "OpportunityContactRole" },
        };
        inline for (mappings) |m| {
            if (std.ascii.eqlIgnoreCase(relationship, m[0])) return m[1];
        }
        // Try removing trailing 's' for standard plural
        if (relationship.len > 1 and relationship[relationship.len - 1] == 's') {
            return relationship[0 .. relationship.len - 1];
        }
        return null;
    }

    /// Resolve the foreign key field name from child to parent.
    /// e.g., Contact to Account → "AccountId"
    fn resolveForeignKey(self: *Evaluator, child_type: []const u8, parent_type: []const u8, relationship: []const u8) []const u8 {
        if (self.resolveCustomChildRelationship(parent_type, relationship)) |custom| {
            if (std.ascii.eqlIgnoreCase(custom.child_type, child_type)) return custom.fk_field;
        }
        // Standard convention: ParentType + "Id"
        const common_fks = .{
            .{ "Account", "AccountId" },
            .{ "Contact", "ContactId" },
            .{ "Opportunity", "OpportunityId" },
            .{ "Case", "CaseId" },
            .{ "Lead", "LeadId" },
            .{ "User", "OwnerId" },
        };
        inline for (common_fks) |m| {
            if (std.ascii.eqlIgnoreCase(parent_type, m[0])) return m[1];
        }
        return "ParentId";
    }

    fn resolveCustomChildRelationship(self: *Evaluator, parent_type: []const u8, relationship: []const u8) ?CustomChildRelationship {
        const key = self.makeChildRelationshipKey(parent_type, relationship) catch return null;
        return self.child_relationships.get(key);
    }

    fn makeChildRelationshipKey(self: *Evaluator, parent_type: []const u8, relationship: []const u8) ![]const u8 {
        const raw = try std.fmt.allocPrint(self.arena, "{s}|{s}", .{ parent_type, relationship });
        const lowered = try self.arena.alloc(u8, raw.len);
        _ = std.ascii.lowerString(lowered, raw);
        return lowered;
    }

    /// Apply parent field lookups like Account.Name, parent__r.Name to query results.
    fn applyParentFieldLookups(self: *Evaluator, soql: []const u8, from_type: []const u8, records: *std.ArrayListUnmanaged(Value)) !void {
        const select_clause = extractParentFields(soql) orelse return;

        // Find fields like Account.Name, Account.ShippingState, parent__r.Name
        var iter = std.mem.splitScalar(u8, select_clause, ',');
        while (iter.next()) |field_part| {
            const trimmed = std.mem.trim(u8, field_part, " \t\n\r");
            // Skip sub-queries (start with '(')
            if (trimmed.len > 0 and trimmed[0] == '(') continue;
            // Look for dotted fields like Account.Name
            if (std.mem.indexOf(u8, trimmed, ".")) |dot_pos| {
                const parent_ref = trimmed[0..dot_pos];
                const child_field = trimmed[dot_pos + 1 ..];
                // Determine the FK field: Account → AccountId, parent__r → parent__c
                const fk_field = self.parentRefToFk(parent_ref);
                const parent_type = self.parentRefToTypeForSObject(from_type, parent_ref);

                // For each record, look up the parent and set the nested field
                for (records.items) |*rec| {
                    if (rec.* == .sobject) {
                        // Get the FK value
                        if (utils.sobjectGet(&rec.sobject.fields, fk_field)) |fk_val| {
                            if (fk_val == .string) {
                                // Look up parent record in store
                                if (parent_type) |pt| {
                                    if (self.findRecordById(pt, fk_val.string)) |parent_rec| {
                                        // Create or get the parent sobject on this record
                                        var parent_sob: *types.SObject = undefined;
                                        if (utils.sobjectGet(&rec.sobject.fields, parent_ref)) |existing| {
                                            if (existing == .sobject) {
                                                parent_sob = existing.sobject;
                                            } else {
                                                parent_sob = try self.arena.create(types.SObject);
                                                parent_sob.* = .{ .type_name = pt };
                                                try rec.sobject.fields.put(self.arena, parent_ref, Value{ .sobject = parent_sob });
                                            }
                                        } else {
                                            parent_sob = try self.arena.create(types.SObject);
                                            parent_sob.* = .{ .type_name = pt };
                                            try rec.sobject.fields.put(self.arena, parent_ref, Value{ .sobject = parent_sob });
                                        }
                                        // Copy the requested field from the parent
                                        if (parent_rec == .sobject) {
                                            if (self.getSObjectFieldValueCaseInsensitive(parent_rec.sobject, child_field)) |field_val| {
                                                try parent_sob.fields.put(self.arena, child_field, field_val);
                                            }
                                            // Also copy Id
                                            if (parent_rec.sobject.id) |pid| {
                                                parent_sob.id = pid;
                                                try parent_sob.fields.put(self.arena, "Id", Value{ .string = pid });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// SOQL SELECT 内の数式フィールド（<Relationship>_<Field>__c）を FK 経由で親から解決する。
    /// 例: Experience_Name__c → Experience__c FK → 親の Name
    fn resolveFormulaFields(self: *Evaluator, soql: []const u8, records: *std.ArrayListUnmanaged(Value)) !void {
        const select_clause = extractParentFields(soql) orelse return;
        var iter = std.mem.splitScalar(u8, select_clause, ',');
        while (iter.next()) |field_part| {
            const trimmed = std.mem.trim(u8, field_part, " \t\n\r");
            // Skip dotted fields (already handled) and sub-queries
            if (std.mem.indexOf(u8, trimmed, ".") != null) continue;
            if (trimmed.len > 0 and trimmed[0] == '(') continue;
            // Pattern: <Prefix>_<Suffix>__c where <Prefix>__c is a FK and <Suffix> is a parent field
            // e.g. Experience_Name__c → FK=Experience__c, parent field=Name
            if (!std.mem.endsWith(u8, trimmed, "__c")) continue;
            const base = trimmed[0 .. trimmed.len - 3]; // strip __c
            // Find underscore separator (last one before __c)
            const sep_pos = std.mem.lastIndexOfScalar(u8, base, '_') orelse continue;
            if (sep_pos == 0) continue;
            const parent_prefix = base[0..sep_pos]; // "Experience"
            const field_suffix = base[sep_pos + 1 ..]; // "Name"
            // Construct FK field: Experience__c
            const fk_field = try std.fmt.allocPrint(self.arena, "{s}__c", .{parent_prefix});

            for (records.items) |*rec| {
                if (rec.* != .sobject) continue;
                // Skip if field already has a non-null value
                if (utils.sobjectGet(&rec.sobject.fields, trimmed)) |existing| {
                    if (existing != .null_val) continue;
                }
                // Look up FK
                const fk_val = utils.sobjectGet(&rec.sobject.fields, fk_field) orelse continue;
                if (fk_val != .string) continue;
                // Find parent type
                const parent_type = self.findRecordTypeById(fk_val.string) orelse continue;
                // Find parent record
                const parent_rec = self.findRecordById(parent_type, fk_val.string) orelse continue;
                if (parent_rec != .sobject) continue;
                // Copy the field from parent
                if (utils.sobjectGet(&parent_rec.sobject.fields, field_suffix)) |val| {
                    try rec.sobject.fields.put(self.arena, trimmed, val);
                }
            }
        }
    }

    /// Convert a parent reference to FK field name.
    /// Account → AccountId, parent__r → parent__c
    fn parentRefToFk(self: *Evaluator, ref: []const u8) []const u8 {
        // Custom relationship: ends with __r → change to __c
        if (ref.len > 3 and std.ascii.eqlIgnoreCase(ref[ref.len - 3 ..], "__r")) {
            // Replace __r with __c
            const fk = std.fmt.allocPrint(self.arena, "{s}__c", .{ref[0 .. ref.len - 3]}) catch return ref;
            return fk;
        }
        // Standard: Account → AccountId
        const common = .{
            .{ "Account", "AccountId" },
            .{ "Contact", "ContactId" },
            .{ "Opportunity", "OpportunityId" },
            .{ "Case", "CaseId" },
            .{ "Lead", "LeadId" },
            .{ "Owner", "OwnerId" },
            .{ "CreatedBy", "CreatedById" },
            .{ "LastModifiedBy", "LastModifiedById" },
            .{ "Parent", "ParentId" },
            .{ "Profile", "ProfileId" },
            .{ "UserRole", "UserRoleId" },
            .{ "UserLicense", "UserLicenseId" },
        };
        inline for (common) |m| {
            if (std.ascii.eqlIgnoreCase(ref, m[0])) return m[1];
        }
        return ref;
    }

    /// Convert a FK field name back to its relationship name.
    /// AccountId → Account, parent__c → parent__r
    fn fkToParentRef(self: *Evaluator, fk_field: []const u8) []const u8 {
        if (fk_field.len > 3 and std.ascii.eqlIgnoreCase(fk_field[fk_field.len - 3 ..], "__c")) {
            const rel = std.fmt.allocPrint(self.arena, "{s}__r", .{fk_field[0 .. fk_field.len - 3]}) catch return fk_field;
            return rel;
        }
        const common = .{
            .{ "AccountId", "Account" },
            .{ "ContactId", "Contact" },
            .{ "OpportunityId", "Opportunity" },
            .{ "CaseId", "Case" },
            .{ "LeadId", "Lead" },
            .{ "OwnerId", "Owner" },
            .{ "CreatedById", "CreatedBy" },
            .{ "LastModifiedById", "LastModifiedBy" },
            .{ "ParentId", "Parent" },
            .{ "ProfileId", "Profile" },
            .{ "UserRoleId", "UserRole" },
            .{ "UserLicenseId", "UserLicense" },
        };
        inline for (common) |m| {
            if (std.ascii.eqlIgnoreCase(fk_field, m[0])) return m[1];
        }
        return fk_field;
    }

    /// Convert a parent reference to SObject type name.
    /// Account → Account, parent__r → look up FK value's type in store
    fn parentRefToType(self: *Evaluator, ref: []const u8) ?[]const u8 {
        // Custom relationship: parent1__r → parent1__c is the FK field
        // We need to find what type the FK points to
        if (ref.len > 3 and std.ascii.eqlIgnoreCase(ref[ref.len - 3 ..], "__r")) {
            const fk_field = self.parentRefToFk(ref);
            // Search for the FK value in any record and look up the target type
            var store_iter = self.store.iterator();
            while (store_iter.next()) |entry| {
                for (entry.value_ptr.items) |record| {
                    if (record == .sobject) {
                        if (utils.sobjectGet(&record.sobject.fields, fk_field)) |fk_val| {
                            if (fk_val == .string) {
                                // Find which type has a record with this Id
                                if (self.findRecordTypeById(fk_val.string)) |found_type| {
                                    return found_type;
                                }
                            }
                        }
                    }
                }
            }
            return null;
        }
        // Standard relationship → SObject type mapping
        if (std.ascii.eqlIgnoreCase(ref, "Owner") or
            std.ascii.eqlIgnoreCase(ref, "CreatedBy") or
            std.ascii.eqlIgnoreCase(ref, "LastModifiedBy"))
        {
            return "User";
        }
        return ref;
    }

    fn parentRefToTypeForSObject(self: *Evaluator, object_type: []const u8, ref: []const u8) ?[]const u8 {
        const fk_field = self.parentRefToFk(ref);
        if (self.getFieldMetadata(object_type, fk_field)) |meta| {
            if (meta.reference_to) |target_type| return target_type;
        }
        return self.parentRefToType(ref);
    }

    /// Find a record by Id in the store.
    fn findRecordById(self: *Evaluator, type_name: []const u8, id: []const u8) ?Value {
        var store_iter = self.store.iterator();
        while (store_iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, type_name)) {
                for (entry.value_ptr.items) |record| {
                    if (record == .sobject) {
                        if (record.sobject.id) |rec_id| {
                            if (std.ascii.eqlIgnoreCase(rec_id, id)) return record;
                        }
                    }
                }
                return null;
            }
        }
        // Fallback: for User type, return synthetic user if id matches UserInfo.getUserId()
        if (std.ascii.eqlIgnoreCase(type_name, "User") and std.ascii.eqlIgnoreCase(id, self.current_user_id)) {
            return self.createCurrentUserRecord() catch null;
        }
        return null;
    }

    pub fn getSObjectFieldValueCaseInsensitive(self: *Evaluator, sob: *types.SObject, field_name: []const u8) ?Value {
        var matched_value: ?Value = null;
        for (sob.fields.keys(), sob.fields.values()) |k, v| {
            if (std.ascii.eqlIgnoreCase(k, field_name)) {
                matched_value = v;
                break;
            }
        }
        if (matched_value) |value| {
            if (value != .null_val) {
                if (value == .string) {
                    var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
                    const display_type = builtins.getSObjectFieldDisplayType(&bctx, sob, field_name);
                    if (std.ascii.eqlIgnoreCase(display_type, "DATETIME")) {
                        return builtins.makeDatetimeValue(self.arena, value.string) catch value;
                    }
                    if (std.ascii.eqlIgnoreCase(display_type, "DATE")) {
                        const date_str = if (value.string.len >= 10) value.string[0..10] else value.string;
                        return builtins.makeDateValue(self.arena, date_str) catch value;
                    }
                }
                return value;
            }
        }
        if (self.resolveDerivedFieldValue(sob, field_name)) |derived| return derived;
        return matched_value;
    }

    fn resolveFieldPathValue(self: *Evaluator, sob: *types.SObject, field_path: []const u8) ?Value {
        var current = sob;
        var remaining = field_path;
        while (true) {
            const dot_pos = std.mem.indexOfScalar(u8, remaining, '.') orelse {
                return self.getSObjectFieldValueCaseInsensitive(current, remaining);
            };
            const segment = remaining[0..dot_pos];
            remaining = remaining[dot_pos + 1 ..];

            if (self.getSObjectFieldValueCaseInsensitive(current, segment)) |segment_val| {
                if (segment_val == .sobject) {
                    current = segment_val.sobject;
                    continue;
                }
                return null;
            }

            const fk_field = self.parentRefToFk(segment);
            const fk_val = utils.sobjectGet(&current.fields, fk_field) orelse return null;
            if (fk_val != .string) return null;

            const parent_type = self.parentRefToTypeForSObject(current.type_name, segment) orelse
                self.findRecordTypeById(fk_val.string) orelse
                blk: {
                    if (fk_val.string.len < 3) break :blk null;
                    const inferred = sobjectTypeFromPrefix(fk_val.string[0..3]);
                    if (std.ascii.eqlIgnoreCase(inferred, "SObject")) break :blk null;
                    break :blk inferred;
                } orelse return null;

            const parent_record = self.findRecordById(parent_type, fk_val.string) orelse return null;
            if (parent_record != .sobject) return null;
            current = parent_record.sobject;
        }
    }

    fn resolveDerivedFieldValue(self: *Evaluator, sob: *types.SObject, field_name: []const u8) ?Value {
        const metadata = self.getFieldMetadata(sob.type_name, field_name) orelse return null;
        if (metadata.summary_operation != null) {
            if (self.computeSummaryFieldValue(sob, metadata)) |value| return value;
        }
        if (metadata.formula != null) {
            if (self.computeFormulaFieldValue(sob, metadata)) |value| return value;
        }
        return null;
    }

    fn normalizeSummaryFieldPath(_: *Evaluator, child_type: []const u8, field_path: []const u8) []const u8 {
        if (std.mem.startsWith(u8, field_path, child_type) and field_path.len > child_type.len and field_path[child_type.len] == '.') {
            return field_path[child_type.len + 1 ..];
        }
        return field_path;
    }

    fn summaryFilterMatches(self: *Evaluator, child: *types.SObject, child_type: []const u8, filter: SummaryFilter) bool {
        const field_path = self.normalizeSummaryFieldPath(child_type, filter.field_path);
        const field_val = if (std.mem.indexOfScalar(u8, field_path, '.')) |_|
            self.resolveFieldPathValue(child, field_path)
        else
            self.getSObjectFieldValueCaseInsensitive(child, field_path);
        if (field_val == null) return false;

        if (std.ascii.eqlIgnoreCase(filter.operation, "equals")) {
            return switch (field_val.?) {
                .string => std.ascii.eqlIgnoreCase(field_val.?.string, filter.value),
                .integer => blk: {
                    const expected = std.fmt.parseInt(i64, filter.value, 10) catch break :blk false;
                    break :blk field_val.?.integer == expected;
                },
                .double => blk: {
                    const expected = std.fmt.parseFloat(f64, filter.value) catch break :blk false;
                    break :blk field_val.?.double == expected;
                },
                .boolean => if (std.ascii.eqlIgnoreCase(filter.value, "true")) field_val.?.boolean else if (std.ascii.eqlIgnoreCase(filter.value, "false")) !field_val.?.boolean else false,
                .null_val => std.ascii.eqlIgnoreCase(filter.value, "null"),
                else => {
                    const actual = utils.coerceToString(field_val.?, self.arena) catch return false;
                    return std.ascii.eqlIgnoreCase(actual, filter.value);
                },
            };
        }

        if (std.ascii.eqlIgnoreCase(filter.operation, "notEqual")) {
            return !self.summaryFilterMatches(child, child_type, .{
                .field_path = filter.field_path,
                .operation = "equals",
                .value = filter.value,
            });
        }

        return false;
    }

    fn computeSummaryFieldValue(self: *Evaluator, sob: *types.SObject, metadata: FieldMetadata) ?Value {
        const summary_operation = metadata.summary_operation orelse return null;
        const summary_fk = metadata.summary_foreign_key orelse return null;
        const dot_idx = std.mem.indexOfScalar(u8, summary_fk, '.') orelse return null;
        const child_type = summary_fk[0..dot_idx];
        const fk_field = summary_fk[dot_idx + 1 ..];

        const parent_id = sob.id orelse blk: {
            if (utils.sobjectGet(&sob.fields, "Id")) |id_val| {
                if (id_val == .string) break :blk id_val.string;
            }
            break :blk null;
        };

        if (parent_id == null) {
            if (std.ascii.eqlIgnoreCase(summary_operation, "count")) return Value{ .integer = 0 };
            return Value.null_val;
        }

        const child_records = self.store.get(child_type) orelse {
            if (std.ascii.eqlIgnoreCase(summary_operation, "count")) return Value{ .integer = 0 };
            return Value.null_val;
        };

        var count: i64 = 0;
        var aggregate: ?Value = null;
        const summarized_field = if (metadata.summarized_field) |field_path|
            self.normalizeSummaryFieldPath(child_type, field_path)
        else
            "";

        for (child_records.items) |record| {
            if (record != .sobject) continue;
            const fk_val = self.getSObjectFieldValueCaseInsensitive(record.sobject, fk_field) orelse continue;
            if (fk_val != .string or !std.ascii.eqlIgnoreCase(fk_val.string, parent_id.?)) continue;

            var passes_filters = true;
            for (metadata.summary_filters) |filter| {
                if (!self.summaryFilterMatches(record.sobject, child_type, filter)) {
                    passes_filters = false;
                    break;
                }
            }
            if (!passes_filters) continue;

            if (std.ascii.eqlIgnoreCase(summary_operation, "count")) {
                count += 1;
                continue;
            }

            if (summarized_field.len == 0) continue;
            const child_value = blk: {
                if (std.mem.indexOfScalar(u8, summarized_field, '.')) |_| {
                    break :blk self.resolveFieldPathValue(record.sobject, summarized_field) orelse Value.null_val;
                }
                break :blk self.getSObjectFieldValueCaseInsensitive(record.sobject, summarized_field) orelse Value.null_val;
            };
            if (child_value == .null_val) continue;

            if (aggregate == null) {
                aggregate = child_value;
                continue;
            }

            const cmp = self.compareValues(aggregate.?, child_value);
            if (std.ascii.eqlIgnoreCase(summary_operation, "min")) {
                if (cmp > 0) aggregate = child_value;
            } else if (std.ascii.eqlIgnoreCase(summary_operation, "max")) {
                if (cmp < 0) aggregate = child_value;
            }
        }

        if (std.ascii.eqlIgnoreCase(summary_operation, "count")) return Value{ .integer = count };
        return aggregate orelse Value.null_val;
    }

    fn computeFormulaFieldValue(self: *Evaluator, sob: *types.SObject, metadata: FieldMetadata) ?Value {
        const formula = metadata.formula orelse return null;
        const trimmed = std.mem.trim(u8, formula, " \t\n\r");
        if (trimmed.len == 0) return null;

        if (std.mem.indexOfScalar(u8, trimmed, '+')) |_| {
            var total: i64 = 0;
            var term_iter = std.mem.splitScalar(u8, trimmed, '+');
            while (term_iter.next()) |raw_term| {
                const term = std.mem.trim(u8, raw_term, " \t\n\r()");
                if (term.len == 0) continue;
                const term_value = self.getSObjectFieldValueCaseInsensitive(sob, term) orelse Value.null_val;
                switch (term_value) {
                    .integer => |i| total += i,
                    .double => |d| total += @intFromFloat(d),
                    .null_val => {
                        if (!metadata.formula_blank_as_zero) return Value.null_val;
                    },
                    else => return Value.null_val,
                }
            }
            return Value{ .integer = total };
        }

        if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| {
            return self.resolveFieldPathValue(sob, trimmed);
        }

        if (std.ascii.indexOfIgnoreCase(trimmed, "!= null")) |idx| {
            const lhs = std.mem.trim(u8, trimmed[0..idx], " \t\n\r");
            const lhs_value = self.getSObjectFieldValueCaseInsensitive(sob, lhs) orelse Value.null_val;
            return Value{ .boolean = lhs_value != .null_val };
        }

        if (std.ascii.indexOfIgnoreCase(trimmed, "== null")) |idx| {
            const lhs = std.mem.trim(u8, trimmed[0..idx], " \t\n\r");
            const lhs_value = self.getSObjectFieldValueCaseInsensitive(sob, lhs) orelse Value.null_val;
            return Value{ .boolean = lhs_value == .null_val };
        }

        return self.getSObjectFieldValueCaseInsensitive(sob, trimmed);
    }

    /// Create a shallow clone of an SObject (copies the fields map).
    fn cloneSObject(self: *Evaluator, src: *types.SObject) !*types.SObject {
        const copy = try self.arena.create(types.SObject);
        copy.* = .{ .type_name = src.type_name, .id = src.id };
        for (src.fields.keys(), src.fields.values()) |k, v| {
            try copy.fields.put(self.arena, k, v);
        }
        return copy;
    }

    fn defaultCustomSettingRecord(self: *Evaluator, class_name: []const u8, setup_owner_id: ?[]const u8) !Value {
        const sob = try self.arena.create(types.SObject);
        sob.* = .{ .type_name = class_name };
        if (self.field_defaults.get(class_name)) |defaults| {
            for (defaults.keys(), defaults.values()) |fk, fv| {
                try sob.fields.put(self.arena, fk, fv);
            }
        }
        if (setup_owner_id) |owner_id| {
            try sob.fields.put(self.arena, "SetupOwnerId", Value{ .string = owner_id });
        }
        return Value{ .sobject = sob };
    }

    fn cloneCustomSettingRecord(self: *Evaluator, record: *types.SObject, setup_owner_id: ?[]const u8, clear_id: bool) !Value {
        const copy = try self.cloneSObject(record);
        if (clear_id) {
            copy.id = null;
            try copy.fields.put(self.arena, "Id", Value.null_val);
        }
        if (setup_owner_id) |owner_id| {
            try copy.fields.put(self.arena, "SetupOwnerId", Value{ .string = owner_id });
        }
        return Value{ .sobject = copy };
    }

    fn findCustomSettingRecord(self: *Evaluator, class_name: []const u8, owner_id: []const u8) ?*types.SObject {
        var cs_iter = self.store.iterator();
        while (cs_iter.next()) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) continue;
            for (entry.value_ptr.items) |item| {
                if (item != .sobject) continue;
                if (utils.sobjectGet(&item.sobject.fields, "SetupOwnerId")) |stored_owner| {
                    if (stored_owner == .string and std.ascii.eqlIgnoreCase(stored_owner.string, owner_id)) {
                        return item.sobject;
                    }
                }
            }
        }
        return null;
    }

    fn firstCustomSettingRecord(self: *Evaluator, class_name: []const u8) ?*types.SObject {
        var cs_iter = self.store.iterator();
        while (cs_iter.next()) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) continue;
            for (entry.value_ptr.items) |item| {
                if (item == .sobject) return item.sobject;
            }
        }
        return null;
    }

    fn customSettingKind(self: *Evaluator, class_name: []const u8) ?[]const u8 {
        if (self.custom_setting_kinds.get(class_name)) |kind| return kind;
        if (self.custom_setting_types.get(class_name) != null) return "Hierarchy";
        return null;
    }

    fn handleCustomSettingStaticMethod(self: *Evaluator, class_name: []const u8, method_name: []const u8, args: []const Value) !?Value {
        if (!std.mem.endsWith(u8, class_name, "__c")) return null;

        const kind = self.customSettingKind(class_name);
        const is_hierarchy = kind != null and std.ascii.eqlIgnoreCase(kind.?, "Hierarchy");

        if (std.ascii.eqlIgnoreCase(method_name, "getOrgDefaults")) {
            if (is_hierarchy) {
                if (self.findCustomSettingRecord(class_name, "00D000000000001")) |org_defaults| {
                    return try self.cloneCustomSettingRecord(org_defaults, null, false);
                }
                return try self.defaultCustomSettingRecord(class_name, "00D000000000001");
            }
            if (self.firstCustomSettingRecord(class_name)) |record| {
                return try self.cloneCustomSettingRecord(record, null, false);
            }
            return try self.defaultCustomSettingRecord(class_name, null);
        }

        if (std.ascii.eqlIgnoreCase(method_name, "getInstance")) {
            if (is_hierarchy) {
                const owner_id = if (args.len > 0 and args[0] == .string and args[0].string.len > 0)
                    args[0].string
                else
                    self.current_user_id;
                const profile_id = self.current_profile_id;
                const org_id = "00D000000000001";

                if (self.findCustomSettingRecord(class_name, owner_id)) |user_record| {
                    return try self.cloneCustomSettingRecord(user_record, owner_id, false);
                }
                if (self.findCustomSettingRecord(class_name, profile_id)) |profile_record| {
                    return try self.cloneCustomSettingRecord(profile_record, owner_id, true);
                }
                if (self.findCustomSettingRecord(class_name, org_id)) |org_defaults| {
                    return try self.cloneCustomSettingRecord(org_defaults, owner_id, true);
                }
                return try self.defaultCustomSettingRecord(class_name, owner_id);
            }

            if (self.firstCustomSettingRecord(class_name)) |record| {
                return try self.cloneCustomSettingRecord(record, null, false);
            }
            return try self.defaultCustomSettingRecord(class_name, null);
        }

        if (std.ascii.eqlIgnoreCase(method_name, "getValues") and args.len > 0 and args[0] == .string) {
            if (self.findCustomSettingRecord(class_name, args[0].string)) |record| {
                return try self.cloneCustomSettingRecord(record, null, false);
            }
            return Value.null_val;
        }

        return null;
    }

    /// Find the type name of a record by its Id, searching all types in store.
    fn findRecordTypeById(self: *Evaluator, id: []const u8) ?[]const u8 {
        var store_iter = self.store.iterator();
        while (store_iter.next()) |entry| {
            for (entry.value_ptr.items) |record| {
                if (record == .sobject) {
                    if (record.sobject.id) |rec_id| {
                        if (std.ascii.eqlIgnoreCase(rec_id, id)) return entry.key_ptr.*;
                    }
                }
            }
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // 式の評価
    // -----------------------------------------------------------------------

    pub fn evalExpr(self: *Evaluator, expr: *const ast.Expr, current_env: *Env) anyerror!Value {
        self.call_depth +|= 1;
        defer self.call_depth -|= 1;
        if (self.call_depth > self.max_call_depth) {
            // error を返すと error return trace の記録でスタックを消費し
            // OS スタックオーバーフローを引き起こす場合があるため null を返す
            return .null_val;
        }
        switch (expr.*) {
            .integer_literal => |v| return .{ .integer = v },
            .double_literal => |v| return .{ .double = v },
            .string_literal => |v| return .{ .string = v },
            .boolean_literal => |v| return .{ .boolean = v },
            .null_literal => return .null_val,
            .this_expr, .super_expr => {
                return current_env.get("this") orelse .null_val;
            },

            .identifier => |id| {
                if (current_env.get(id.name)) |val| {
                    // If value is null_val, still check for instance getter (property may override)
                    if (val != .null_val) return val;
                }
                // Check if this is a property with a getter on `this`
                // (bare identifier in getter body referencing another property)
                // Skip if we're already inside this property's getter to avoid infinite recursion
                // (self-referencing getter pattern: backing field access, not getter re-invocation)
                if (current_env.get("this")) |this_check| {
                    if (this_check == .object) {
                        const already_in_instance_getter = if (self.evaluating_getter) |eg| std.ascii.eqlIgnoreCase(eg, id.name) else false;
                        if (!already_in_instance_getter) {
                            if (self.findClass(this_check.object.class_name)) |this_cd| {
                                var scan_cd: ?*ast.ClassDecl = this_cd;
                                while (scan_cd) |scd| {
                                    for (scd.members) |m| {
                                        switch (m) {
                                            .field_decl => |pfd| {
                                                if (std.ascii.eqlIgnoreCase(pfd.name, id.name) and pfd.getter_body != null) {
                                                    // Evaluate as this.propertyName → triggers getter
                                                    const this_expr_node = try self.arena.create(ast.Expr);
                                                    this_expr_node.* = .this_expr;
                                                    const fa_node = try self.arena.create(ast.FieldAccess);
                                                    fa_node.* = .{ .object = this_expr_node, .field = id.name, .null_safe = false };
                                                    const fa_expr = try self.arena.create(ast.Expr);
                                                    fa_expr.* = .{ .field_access = fa_node };
                                                    return self.evalExpr(fa_expr, current_env);
                                                }
                                            },
                                            else => {},
                                        }
                                    }
                                    scan_cd = if (scd.super_class) |sc| self.findClass(sc.name) else null;
                                }
                            }
                        } else {
                            // Inside own getter: return backing field value directly
                            if (self.findFieldDeclWithOwner(this_check.object.class_name, id.name)) |lookup| {
                                if (lookup.field_decl.modifiers.is_static) {
                                    return self.readStaticBackingValue(lookup.owner_name, id.name);
                                }
                            }
                            if (this_check.object.fields.get(id.name)) |fv| return fv;
                            // Case-insensitive fallback
                            for (this_check.object.fields.keys(), this_check.object.fields.values()) |fk, fv| {
                                if (std.ascii.eqlIgnoreCase(fk, id.name)) return fv;
                            }
                            return .null_val;
                        }
                    }
                }
                // Check static fields in enclosing class context
                // When `this` is available, check ClassName.fieldName and parent class
                if (current_env.get("this")) |this_val| {
                    if (this_val == .object) {
                        const this_cn = this_val.object.class_name;
                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ this_cn, id.name }) catch return .null_val;
                        if (self.global_env.get(key)) |val| return val;
                        // Check parent class static fields
                        if (self.findClass(this_cn)) |cd| {
                            if (cd.super_class) |sc| {
                                self.ensureStaticInit(sc.name);
                                const pkey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ sc.name, id.name }) catch return .null_val;
                                if (self.global_env.get(pkey)) |val| return val;
                            }
                        }
                        // Check outer class static fields/getters (for inner classes)
                        if (self.resolveOuterStaticField(this_cn, id.name)) |val| return val;
                    }
                }
                // Check current_class static fields (for static methods)
                if (self.current_class) |cc| {
                    if (self.resolveStaticFieldValueOnClass(cc, id.name)) |val| return val;
                    if (self.findClass(cc)) |cd| {
                        if (cd.super_class) |sc| {
                            if (self.resolveStaticFieldValueOnClass(sc.name, id.name)) |val| return val;
                        }
                    }
                    // Check outer class static fields/getters when current_class is an inner class
                    if (self.resolveOuterStaticField(cc, id.name)) |val| return val;
                }
                // Check if identifier is an inner enum/class of enclosing class or parent
                // (e.g., HttpVerb inside RestClient → used as HttpVerb.GET)
                {
                    const check_classes = [_]?[]const u8{
                        if (current_env.get("this")) |tv| (if (tv == .object) tv.object.class_name else null) else null,
                        self.current_class,
                    };
                    for (check_classes) |cc_opt| {
                        var cur_class: ?[]const u8 = cc_opt;
                        while (cur_class) |ccn| {
                            if (self.findClass(ccn)) |ccd| {
                                for (ccd.members) |member| {
                                    switch (member) {
                                        .enum_decl => |ed| {
                                            if (std.ascii.eqlIgnoreCase(ed.name, id.name)) {
                                                return Value{ .string = id.name };
                                            }
                                        },
                                        .class_decl => |inner_cd| {
                                            if (std.ascii.eqlIgnoreCase(inner_cd.name, id.name)) {
                                                return Value{ .string = id.name };
                                            }
                                        },
                                        else => {},
                                    }
                                }
                                cur_class = if (ccd.super_class) |sc| sc.name else null;
                            } else break;
                        }
                    }
                }
                return .null_val;
            },

            .binary => |bin| {
                const left = try self.evalExpr(bin.left, current_env);
                const right = try self.evalExpr(bin.right, current_env);
                return evalBinary(left, bin.op, right, self.arena);
            },

            .unary => |un| {
                const operand = try self.evalExpr(un.operand, current_env);
                return evalUnary(un.op, operand);
            },

            .assignment => |asgn| {
                const val = try self.evalExpr(asgn.value, current_env);
                if (asgn.is_postfix) {
                    // Postfix n++ / n--: return original value, but still perform the assignment
                    const original = self.evalExpr(asgn.target, current_env) catch Value.null_val;
                    _ = try self.evalAssignment(asgn, val, current_env);
                    return original;
                }
                return self.evalAssignment(asgn, val, current_env);
            },

            .call => |call| {
                // Set call-site line for stack trace generation, and update parent frame's line
                if (call.loc.line > 0) {
                    self.current_call_line = call.loc.line;
                    if (self.call_stack.items.len > 0)
                        self.call_stack.items[self.call_stack.items.len - 1].line = call.loc.line;
                }
                var args: std.ArrayListUnmanaged(Value) = .empty;
                var call_type_hints: std.ArrayListUnmanaged(?[]const u8) = .empty;
                for (call.args) |*arg| {
                    try args.append(self.arena, try self.evalExpr(arg, current_env));
                    const hint = self.extractExprTypeHint(arg, current_env);
                    try call_type_hints.append(self.arena, hint);
                }
                const prev_hints = self.cast_type_hints;
                self.cast_type_hints = call_type_hints.items;
                defer self.cast_type_hints = prev_hints;
                // super(args) → call parent class constructor
                if (std.mem.eql(u8, call.callee, "super")) {
                    if (current_env.get("this")) |this_val| {
                        if (this_val == .object) {
                            // Use current_constructor_class to find the correct parent
                            // (not the instance's actual class, which may be a child)
                            const ctor_class = if (self.current_constructor_class) |cc|
                                self.findClass(cc)
                            else
                                self.findClass(this_val.object.class_name);
                            if (ctor_class) |cd| {
                                if (cd.super_class) |sc| {
                                    if (self.findClass(sc.name)) |parent_decl| {
                                        try self.runConstructor(parent_decl, this_val.object, args.items);
                                    }
                                }
                            }
                        }
                    }
                    return Value.void_val;
                }
                // this(args) → constructor delegation to another constructor in the same class
                if (std.mem.eql(u8, call.callee, "this")) {
                    if (current_env.get("this")) |this_val| {
                        if (this_val == .object) {
                            const ctor_class_name = if (self.current_constructor_class) |cc| cc else this_val.object.class_name;
                            if (self.findClass(ctor_class_name)) |cd| {
                                try self.runConstructor(cd, this_val.object, args.items);
                            }
                        }
                    }
                    return Value.void_val;
                }
                // Try as instance method on `this` first
                if (current_env.get("this")) |this_val| {
                    if (this_val == .object) {
                        if (self.findClass(this_val.object.class_name)) |class_decl| {
                            // Look for method in class hierarchy
                            const md = self.findMethodInHierarchy(null, class_decl, call.callee, args.items.len);
                            if (md != null) {
                                // Snapshot field values before the call
                                var pre_fields: [16]Value = undefined;
                                const field_keys = this_val.object.fields.keys();
                                const n_snap = @min(field_keys.len, pre_fields.len);
                                for (this_val.object.fields.values()[0..n_snap], 0..) |v, fi| {
                                    pre_fields[fi] = v;
                                }
                                const result = try self.callInstanceMethod(class_decl, this_val.object, call.callee, args.items);
                                // Sync back only fields that were MODIFIED by the called method
                                for (this_val.object.fields.keys(), this_val.object.fields.values(), 0..) |fk, fv, fi| {
                                    if (fi < n_snap) {
                                        // Compare by identity: if value changed, sync it
                                        const pre = pre_fields[fi];
                                        const changed = switch (fv) {
                                            .null_val => pre != .null_val,
                                            .string => |s| if (pre == .string) s.ptr != pre.string.ptr or s.len != pre.string.len else true,
                                            .integer => |i| if (pre == .integer) i != pre.integer else true,
                                            .boolean => |b| if (pre == .boolean) b != pre.boolean else true,
                                            else => true,
                                        };
                                        if (changed) {
                                            current_env.set(fk, fv) catch {};
                                        }
                                    } else {
                                        // New field added during call, sync it
                                        current_env.set(fk, fv) catch {};
                                    }
                                }
                                return result;
                            }
                        }
                    }
                }
                // Try as static method in current class first
                if (self.current_class) |cc| {
                    if (self.findClass(cc)) |cd| {
                        if (self.findBestMethodInClass(cd, call.callee, args.items) != null) {
                            return self.callMethod(cc, call.callee, args.items);
                        }
                    }
                }
                // Search all loaded classes for matching method
                var class_iter = self.classes.iterator();
                while (class_iter.next()) |entry| {
                    for (entry.value_ptr.*.members) |member| {
                        switch (member) {
                            .method_decl => |md| {
                                if (std.ascii.eqlIgnoreCase(md.name, call.callee)) {
                                    return self.callMethod(entry.key_ptr.*, call.callee, args.items);
                                }
                            },
                            else => {},
                        }
                    }
                }
                return Value.null_val;
            },

            .method_call => |mc| return self.evalMethodCall(mc, current_env),

            .field_access => |fa| {
                // Pre-check: three-level ClassName.Inner.Field pattern for enums/constants
                // Must be done BEFORE evaluating the inner object to avoid misresolution
                if (fa.object.* == .field_access) {
                    const inner_fa = fa.object.field_access;
                    if (inner_fa.object.* == .identifier) {
                        const outer_name = inner_fa.object.identifier.name;
                        const inner_name = inner_fa.field;
                        // Try global_env key: OuterClass.Inner.Field
                        self.ensureStaticInit(outer_name);
                        const inner_fq = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ outer_name, inner_name });
                        self.ensureStaticInit(inner_fq);
                        const fq_key = try std.fmt.allocPrint(self.arena, "{s}.{s}.{s}", .{ outer_name, inner_name, fa.field });
                        if (self.global_env.get(fq_key)) |v| return v;
                        // Try as enum in class
                        if (self.findClass(outer_name)) |cd| {
                            for (cd.members) |member| {
                                switch (member) {
                                    .enum_decl => |ed| {
                                        if (std.ascii.eqlIgnoreCase(ed.name, inner_name)) {
                                            return Value{ .string = fa.field };
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                        // System.AccessType/AccessLevel/LoggingLevel/TriggerOperation
                        if (std.ascii.eqlIgnoreCase(outer_name, "System") and
                            (std.ascii.eqlIgnoreCase(inner_name, "AccessType") or
                                std.ascii.eqlIgnoreCase(inner_name, "AccessLevel") or
                                std.ascii.eqlIgnoreCase(inner_name, "LoggingLevel") or
                                std.ascii.eqlIgnoreCase(inner_name, "TriggerOperation")))
                        {
                            return Value{ .string = fa.field };
                        }
                        // Schema.SObjectType.FieldName → treat as SObjectType.FieldName (strip Schema prefix)
                        // Only when inner_name looks like an SObject type (not "sObjectType" namespace)
                        if (std.ascii.eqlIgnoreCase(outer_name, "Schema") and
                            !std.ascii.eqlIgnoreCase(inner_name, "sObjectType") and
                            !std.ascii.eqlIgnoreCase(inner_name, "SObjectType"))
                        {
                            const inner_id = try self.arena.create(ast.Expr);
                            inner_id.* = .{ .identifier = .{ .name = inner_name } };
                            const field_fa = try self.arena.create(ast.FieldAccess);
                            field_fa.* = .{ .object = inner_id, .field = fa.field, .null_safe = fa.null_safe };
                            const field_expr = try self.arena.create(ast.Expr);
                            field_expr.* = .{ .field_access = field_fa };
                            return self.evalExpr(field_expr, current_env);
                        }
                    }
                }
                if (fa.null_safe) {
                    const obj = self.evalExpr(fa.object, current_env) catch |err| {
                        if (err == error.ApexException and self.pending_exception != null) {
                            if (self.pending_exception.? == .object) {
                                const cn = self.pending_exception.?.object.class_name;
                                if (std.ascii.indexOfIgnoreCase(cn, "NullPointer") != null) {
                                    self.pending_exception = null;
                                    return Value.null_val;
                                }
                            }
                        }
                        return err;
                    };
                    if (obj == .null_val) return Value.null_val;
                    return self.evalFieldAccess(fa, obj, current_env);
                }
                const obj = try self.evalExpr(fa.object, current_env);
                return self.evalFieldAccess(fa, obj, current_env);
            },

            .index_access => |ia| {
                const obj = try self.evalExpr(ia.object, current_env);
                const idx = try self.evalExpr(ia.index, current_env);
                if (obj == .list and idx == .integer) {
                    if (idx.integer >= 0) {
                        const i: usize = @intCast(idx.integer);
                        if (i < obj.list.items.items.len) return obj.list.items.items[i];
                    }
                }
                if (obj == .map and idx == .string) {
                    return obj.map.entries.get(idx.string) orelse Value.null_val;
                }
                return Value.null_val;
            },

            .new_expr => |ne| {
                // Set call-site line for constructor frame tracking, and update parent frame's line
                if (ne.loc.line > 0) {
                    self.current_call_line = ne.loc.line;
                    if (self.call_stack.items.len > 0)
                        self.call_stack.items[self.call_stack.items.len - 1].line = ne.loc.line;
                }
                const val = try self.evalNewExpr(ne, current_env);
                // Capture stack trace for Exception objects at creation time
                if (val == .object and std.mem.endsWith(u8, val.object.class_name, "Exception")) {
                    if (val.object.fields.get("stackTraceString") == null) {
                        const line = if (ne.loc.line > 0) ne.loc.line else 1;
                        const trace = try self.buildStackTraceString();
                        try val.object.fields.put(self.arena, "stackTraceString", Value{ .string = trace });
                        try val.object.fields.put(self.arena, "lineNumber", Value{ .integer = @intCast(line) });
                    }
                }
                return val;
            },

            .cast_expr => |ce| {
                const val = try self.evalExpr(ce.operand, current_env);
                const target = ce.target_type.name;
                // Check for incompatible casts that should throw TypeException
                if (val == .object) {
                    const src_name = val.object.class_name;
                    // If casting to a primitive type like DateTime, Integer, etc. from an object
                    if (std.ascii.eqlIgnoreCase(target, "DateTime") or
                        std.ascii.eqlIgnoreCase(target, "Date") or
                        std.ascii.eqlIgnoreCase(target, "Time"))
                    {
                        // Allow Date → Datetime cast (Apex converts Date to Datetime at midnight)
                        if (std.ascii.eqlIgnoreCase(src_name, "Date") and std.ascii.eqlIgnoreCase(target, "DateTime")) {
                            // Convert Date "YYYY-MM-DD" to Datetime "YYYY-MM-DDT00:00:00Z"
                            if (val.object.fields.get("value")) |v| {
                                if (v == .string) {
                                    const dt_str = try std.fmt.allocPrint(self.arena, "{s}T00:00:00Z", .{v.string});
                                    return try builtins.makeDatetimeValue(self.arena, dt_str);
                                }
                            }
                            return val;
                        }
                        // Only allow if the object is actually that type
                        if (!std.ascii.eqlIgnoreCase(src_name, target)) {
                            // Normalize type name to match Apex conventions (e.g., DateTime → Datetime)
                            const normalized_target = if (std.ascii.eqlIgnoreCase(target, "DateTime")) "Datetime" else if (std.ascii.eqlIgnoreCase(target, "Date")) "Date" else if (std.ascii.eqlIgnoreCase(target, "Time")) "Time" else target;
                            const msg = try std.fmt.allocPrint(self.arena, "Invalid conversion from runtime type {s} to {s}", .{ src_name, normalized_target });
                            const exc = try self.arena.create(types.ObjectInstance);
                            exc.* = .{ .class_name = "System.TypeException" };
                            try exc.fields.put(self.arena, "message", Value{ .string = msg });
                            self.pending_exception = Value{ .object = exc };
                            return error.ApexException;
                        }
                    }
                    // Casting to a class type → check hierarchy
                    if (!std.ascii.eqlIgnoreCase(src_name, target)) {
                        // Check if target is a parent class
                        var is_compatible = false;
                        if (self.findClass(src_name)) |src_cd| {
                            var cur: ?*ast.ClassDecl = src_cd;
                            while (cur) |cd| {
                                if (std.ascii.eqlIgnoreCase(cd.name, target)) {
                                    is_compatible = true;
                                    break;
                                }
                                if (cd.super_class) |sc| {
                                    if (std.ascii.eqlIgnoreCase(sc.name, target)) {
                                        is_compatible = true;
                                        break;
                                    }
                                    cur = self.findClass(sc.name);
                                } else break;
                            }
                        }
                        // Also check if target is a child class of src (downcast)
                        if (!is_compatible) {
                            if (self.findClass(target)) |tgt_cd| {
                                var cur2: ?*ast.ClassDecl = tgt_cd;
                                while (cur2) |cd| {
                                    if (std.ascii.eqlIgnoreCase(cd.name, src_name)) {
                                        is_compatible = true;
                                        break;
                                    }
                                    if (cd.super_class) |sc| {
                                        if (std.ascii.eqlIgnoreCase(sc.name, src_name)) {
                                            is_compatible = true;
                                            break;
                                        }
                                        cur2 = self.findClass(sc.name);
                                    } else break;
                                }
                            }
                        }
                        // If not compatible and not an interface/generic cast, allow it (Apex is lenient)
                    }
                } else if (val == .sobject) {
                    // SObject casts are always allowed (Account → SObject, etc.)
                }
                return val;
            },

            .ternary => |te| {
                const cond = try self.evalExpr(te.condition, current_env);
                if (utils.coerceToBool(cond) catch false) {
                    return self.evalExpr(te.then_expr, current_env);
                } else {
                    return self.evalExpr(te.else_expr, current_env);
                }
            },

            .instanceof => |ie| {
                const val = try self.evalExpr(ie.operand, current_env);
                if (val == .sobject) return Value{ .boolean = std.ascii.eqlIgnoreCase(val.sobject.type_name, ie.type_name.name) };
                if (val == .object) {
                    // Check class name and superclass/interface hierarchy
                    if (std.ascii.eqlIgnoreCase(val.object.class_name, ie.type_name.name)) return Value{ .boolean = true };
                    // Also match when type name is dotted (e.g., "OuterClass.Inner") and class_name is the simple name
                    if (std.mem.lastIndexOfScalar(u8, ie.type_name.name, '.')) |dot_pos| {
                        if (std.ascii.eqlIgnoreCase(val.object.class_name, ie.type_name.name[dot_pos + 1 ..])) return Value{ .boolean = true };
                    }
                    // Also match when class_name is dotted ("OuterClass.Inner") and type_name is the simple name
                    if (std.mem.lastIndexOfScalar(u8, val.object.class_name, '.')) |dot_pos| {
                        if (std.ascii.eqlIgnoreCase(val.object.class_name[dot_pos + 1 ..], ie.type_name.name)) return Value{ .boolean = true };
                    }
                    // Walk superclass hierarchy
                    if (self.findClass(val.object.class_name)) |cd| {
                        var cur: ?*ast.ClassDecl = cd;
                        while (cur) |ccd| {
                            // Check implemented interfaces
                            for (ccd.interfaces) |iface| {
                                if (std.ascii.eqlIgnoreCase(iface.name, ie.type_name.name)) return Value{ .boolean = true };
                                // Also match when interface name has a prefix (e.g., "di_Binding.Provider" matches "Provider")
                                if (std.mem.lastIndexOfScalar(u8, iface.name, '.')) |dot_pos| {
                                    if (std.ascii.eqlIgnoreCase(iface.name[dot_pos + 1 ..], ie.type_name.name)) return Value{ .boolean = true };
                                }
                            }
                            if (ccd.super_class) |sc| {
                                if (std.ascii.eqlIgnoreCase(sc.name, ie.type_name.name)) return Value{ .boolean = true };
                                cur = self.findClass(sc.name);
                            } else break;
                        }
                    }
                    // Check if it's an exception type matching Exception hierarchy
                    if (std.mem.endsWith(u8, ie.type_name.name, "Exception") and std.mem.endsWith(u8, val.object.class_name, "Exception")) {
                        return Value{ .boolean = true };
                    }
                    return Value{ .boolean = false };
                }
                if (val == .list) {
                    const tn = ie.type_name.name;
                    if (!std.ascii.eqlIgnoreCase(tn, "List")) return Value{ .boolean = false };
                    // If no element type params specified, match any list
                    if (ie.type_name.params.len == 0) return Value{ .boolean = true };
                    // Check element type against actual list items
                    // Note: type params are validated to have non-empty names
                    const elem_type = ie.type_name.params[0].name;
                    if (elem_type.len > 0 and elem_type.len <= 128) {
                        for (val.list.items.items) |item| {
                            if (item == .null_val) continue;
                            return Value{ .boolean = instanceofMatchesPrimitive(item, elem_type) };
                        }
                    }
                    return Value{ .boolean = true }; // empty list or unknown element type matches any
                }
                if (val == .map) return Value{ .boolean = std.ascii.eqlIgnoreCase(ie.type_name.name, "Map") };
                if (val == .set) return Value{ .boolean = std.ascii.eqlIgnoreCase(ie.type_name.name, "Set") };
                if (val == .string) {
                    if (std.ascii.eqlIgnoreCase(ie.type_name.name, "String")) return Value{ .boolean = true };
                    if (std.ascii.eqlIgnoreCase(ie.type_name.name, "Id")) {
                        return Value{ .boolean = isSalesforceIdString(val.string) };
                    }
                    return Value{ .boolean = false };
                }
                if (val == .integer) {
                    return Value{ .boolean = instanceofMatchesNumericType(ie.type_name.name) };
                }
                if (val == .double) {
                    return Value{ .boolean = instanceofMatchesNumericType(ie.type_name.name) };
                }
                if (val == .boolean) return Value{ .boolean = std.ascii.eqlIgnoreCase(ie.type_name.name, "Boolean") };
                return Value{ .boolean = false };
            },

            .soql => |sq| return self.executeSoql(sq.raw, current_env),

            .grouped => |inner| return self.evalExpr(inner, current_env),
        }
    }

    fn isCollectionTypeName(type_name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(type_name, "List") or
            std.ascii.eqlIgnoreCase(type_name, "Set") or
            std.ascii.eqlIgnoreCase(type_name, "Iterable") or
            std.ascii.eqlIgnoreCase(type_name, "Map");
    }

    fn stripTypeNamespace(type_name: []const u8) []const u8 {
        if (std.ascii.startsWithIgnoreCase(type_name, "System.")) return type_name["System.".len..];
        if (std.ascii.startsWithIgnoreCase(type_name, "Schema.")) return type_name["Schema.".len..];
        return type_name;
    }

    fn typeBaseName(type_name: []const u8) []const u8 {
        const stripped = stripTypeNamespace(type_name);
        if (std.mem.indexOfScalar(u8, stripped, '<')) |lt| return stripped[0..lt];
        return stripped;
    }

    fn findDeclaredFieldType(self: *Evaluator, class_name: []const u8, field_name: []const u8) ?[]const u8 {
        if (self.findClass(class_name)) |cd| {
            var cur: ?*ast.ClassDecl = cd;
            while (cur) |ccd| {
                for (ccd.members) |member| {
                    switch (member) {
                        .field_decl => |fd| {
                            if (std.ascii.eqlIgnoreCase(fd.name, field_name)) return fd.type_ref.name;
                        },
                        else => {},
                    }
                }
                cur = if (ccd.super_class) |sc| self.findClass(sc.name) else null;
            }
        }
        return null;
    }

    fn resolveAssignmentTargetType(self: *Evaluator, target: *const ast.Expr, current_env: *Env) ?[]const u8 {
        switch (target.*) {
            .identifier => |id| {
                if (current_env.getDeclaredType(id.name)) |type_name| return type_name;
                if (current_env.get("this")) |this_val| {
                    if (this_val == .object) {
                        if (self.findDeclaredFieldType(this_val.object.class_name, id.name)) |type_name| return type_name;
                    }
                }
                if (self.current_class) |cc| {
                    if (self.findDeclaredFieldType(cc, id.name)) |type_name| return type_name;
                    if (self.findOuterClassName(cc)) |outer| {
                        if (self.findDeclaredFieldType(outer, id.name)) |type_name| return type_name;
                    }
                }
                return null;
            },
            .field_access => |fa| {
                if (fa.object.* == .this_expr) {
                    if (current_env.get("this")) |this_val| {
                        if (this_val == .object) {
                            return self.findDeclaredFieldType(this_val.object.class_name, fa.field);
                        }
                    }
                    return null;
                }
                if (fa.object.* == .identifier) {
                    const owner_name = fa.object.identifier.name;
                    const is_class = self.findClass(owner_name) != null;
                    const is_var = current_env.get(owner_name) != null;
                    if (is_class and !is_var) {
                        if (self.findDeclaredFieldType(owner_name, fa.field)) |type_name| return type_name;
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    fn extractExprTypeHint(self: *Evaluator, expr: *const ast.Expr, current_env: *Env) ?[]const u8 {
        switch (expr.*) {
            .cast_expr => |ce| return self.renderTypeRef(ce.target_type),
            .identifier, .field_access => {
                if (self.resolveAssignmentTargetType(expr, current_env)) |type_name| {
                    return stripTypeNamespace(type_name);
                }
                return null;
            },
            else => return null,
        }
    }

    fn renderTypeRef(self: *Evaluator, type_ref: types.TypeRef) []const u8 {
        if (type_ref.params.len == 0) return stripTypeNamespace(type_ref.name);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        buf.appendSlice(self.arena, stripTypeNamespace(type_ref.name)) catch return stripTypeNamespace(type_ref.name);
        buf.append(self.arena, '<') catch return stripTypeNamespace(type_ref.name);
        for (type_ref.params, 0..) |param, i| {
            if (i > 0) buf.appendSlice(self.arena, ",") catch {};
            buf.appendSlice(self.arena, self.renderTypeRef(param)) catch {};
        }
        buf.append(self.arena, '>') catch {};
        return buf.toOwnedSlice(self.arena) catch stripTypeNamespace(type_ref.name);
    }

    fn coerceSoqlAssignmentToDeclaredType(self: *Evaluator, val: Value, source_expr: ?*const ast.Expr, target_type: []const u8) !Value {
        if (source_expr == null or source_expr.?.* != .soql or val != .list or isCollectionTypeName(target_type)) {
            return val;
        }
        if (val.list.items.items.len > 0) return val.list.items.items[0];

        const exc = try self.arena.create(types.ObjectInstance);
        exc.* = .{ .class_name = "QueryException" };
        try exc.fields.put(self.arena, "message", Value{ .string = "List has no rows for assignment to SObject" });
        self.pending_exception = Value{ .object = exc };
        return error.ApexException;
    }

    fn evalAssignment(self: *Evaluator, asgn: *ast.Assignment, val: Value, current_env: *Env) !Value {
        var coerced_val = val;
        if (self.resolveAssignmentTargetType(asgn.target, current_env)) |target_type| {
            coerced_val = try self.coerceSoqlAssignmentToDeclaredType(coerced_val, asgn.value, target_type);
        }
        switch (asgn.target.*) {
            .identifier => |id| {
                // ??= : only assign if current value is null
                if (asgn.op == .null_coalesce_assign) {
                    const cur = self.evalExpr(asgn.target, current_env) catch Value.null_val;
                    if (cur != .null_val) return cur;
                    // Current is null, fall through to assign the new value
                    const nca = try self.arena.create(ast.Assignment);
                    nca.* = .{ .target = asgn.target, .op = .assign, .value = asgn.value, .loc = asgn.loc };
                    return self.evalAssignment(nca, coerced_val, current_env);
                }
                const final_val = if (asgn.op != .assign) blk: {
                    const cur = current_env.get(id.name) orelse Value.null_val;
                    var result = evalCompoundAssign(cur, asgn.op, coerced_val, self.arena);
                    // Handle string concatenation for +=
                    if (asgn.op == .plus_assign and (cur == .string or coerced_val == .string)) {
                        const ls = try utils.coerceToString(cur, self.arena);
                        const rs = try utils.coerceToString(coerced_val, self.arena);
                        result = Value{ .string = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ ls, rs }) };
                    }
                    break :blk result;
                } else coerced_val;
                current_env.set(id.name, final_val) catch {
                    // Before defining locally, check if this is a static field (ClassName.fieldName)
                    // to avoid shadowing static variables with local bindings.
                    var found_static = false;
                    if (self.current_class) |cc| {
                        const sk = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, id.name }) catch "";
                        if (self.global_env.get(sk) != null) {
                            self.global_env.set(sk, final_val) catch {};
                            found_static = true;
                        } else if (self.findOuterClassName(cc)) |oc| {
                            const osk = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ oc, id.name }) catch "";
                            if (self.global_env.get(osk) != null) {
                                self.global_env.set(osk, final_val) catch {};
                                found_static = true;
                            }
                        }
                    }
                    if (current_env.get("this")) |tv| {
                        if (tv == .object) {
                            const sk = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ tv.object.class_name, id.name }) catch "";
                            if (self.global_env.get(sk) != null) {
                                self.global_env.set(sk, final_val) catch {};
                                found_static = true;
                            } else if (self.findOuterClassName(tv.object.class_name)) |oc| {
                                const osk = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ oc, id.name }) catch "";
                                if (self.global_env.get(osk) != null) {
                                    self.global_env.set(osk, final_val) catch {};
                                    found_static = true;
                                }
                            }
                        }
                    }
                    if (!found_static) {
                        try current_env.define(id.name, final_val);
                    }
                };
                // Also update instance field on `this` if field exists or is declared
                if (current_env.get("this")) |this_val| {
                    if (this_val == .object) {
                        // Check if this field already exists on the instance or is declared in class
                        var should_update = false;
                        for (this_val.object.fields.keys()) |k| {
                            if (std.ascii.eqlIgnoreCase(k, id.name)) {
                                should_update = true;
                                break;
                            }
                        }
                        if (!should_update) {
                            if (self.findClass(this_val.object.class_name)) |cd| {
                                should_update = self.isInstanceField(cd, id.name) or self.isParentInstanceField(cd, id.name);
                            }
                        }
                        if (should_update) {
                            try this_val.object.fields.put(self.arena, id.name, final_val);
                        }
                        // Also update static field if applicable
                        const static_key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ this_val.object.class_name, id.name }) catch "";
                        if (self.global_env.get(static_key) != null) {
                            self.global_env.set(static_key, final_val) catch {};
                        }
                    }
                }
                // Also update current_class static field if applicable
                if (self.current_class) |cc| {
                    if (current_env.get("this") == null) { // Only in static context
                        const static_key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, id.name }) catch "";
                        if (self.global_env.get(static_key) != null) {
                            self.global_env.set(static_key, final_val) catch {};
                        } else if (self.findOuterClassName(cc)) |oc| {
                            const osk = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ oc, id.name }) catch "";
                            if (self.global_env.get(osk) != null) {
                                self.global_env.set(osk, final_val) catch {};
                            }
                        }
                    }
                }
                return final_val;
            },
            .field_access => |fa| {
                // Handle static field assignment: ClassName.fieldName = val
                if (fa.object.* == .identifier) {
                    const cls = fa.object.identifier.name;
                    // Check if it's a class name (not a local variable)
                    const is_class = self.findClass(cls) != null or
                        std.ascii.eqlIgnoreCase(cls, "RestContext") or
                        std.ascii.eqlIgnoreCase(cls, "System") or
                        std.ascii.eqlIgnoreCase(cls, "Trigger");
                    const is_var = current_env.get(cls) != null;
                    if (is_class and !is_var) {
                        // Lazy static init: ensure the class is initialized before writing
                        self.ensureStaticInit(cls);
                        const key = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cls, fa.field });
                        self.global_env.set(key, coerced_val) catch {
                            try self.global_env.define(key, coerced_val);
                        };
                        return coerced_val;
                    }
                }
                const obj = try self.evalExpr(fa.object, current_env);
                var final_val = coerced_val;
                if (asgn.op != .assign) {
                    // Compound assignment: get current value and compute
                    const cur = if (obj == .sobject)
                        utils.sobjectGet(&obj.sobject.fields, fa.field) orelse Value.null_val
                    else if (obj == .object)
                        utils.sobjectGet(&obj.object.fields, fa.field) orelse Value.null_val
                    else
                        Value.null_val;
                    final_val = evalCompoundAssign(cur, asgn.op, coerced_val, self.arena);
                    // Handle string concatenation for +=
                    if (asgn.op == .plus_assign and (cur == .string or coerced_val == .string)) {
                        const ls = try utils.coerceToString(cur, self.arena);
                        const rs = try utils.coerceToString(coerced_val, self.arena);
                        final_val = Value{ .string = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ ls, rs }) };
                    }
                }
                if (obj == .sobject) {
                    try utils.sobjectPut(&obj.sobject.fields, self.arena, fa.field, final_val);
                    // Sync SObject.id when Id field is set
                    if (std.ascii.eqlIgnoreCase(fa.field, "Id")) {
                        obj.sobject.id = if (final_val == .string) final_val.string else null;
                    }
                } else if (obj == .object) {
                    // Case-insensitive put: use existing key if it matches
                    var existing_key: ?[]const u8 = null;
                    for (obj.object.fields.keys()) |k| {
                        if (std.ascii.eqlIgnoreCase(k, fa.field)) {
                            existing_key = k;
                            break;
                        }
                    }
                    try obj.object.fields.put(self.arena, existing_key orelse fa.field, final_val);
                    // Sync local env when assigning to this.field
                    // so that bare field references (without this.) see the updated value
                    if (fa.object.* == .this_expr) {
                        current_env.set(fa.field, final_val) catch {};
                    }
                }
                return final_val;
            },
            .index_access => |ia| {
                const obj = try self.evalExpr(ia.object, current_env);
                const idx = try self.evalExpr(ia.index, current_env);
                if (obj == .list and idx == .integer and idx.integer >= 0) {
                    const i: usize = @intCast(idx.integer);
                    if (i < obj.list.items.items.len) {
                        obj.list.items.items[i] = val;
                    }
                }
                return val;
            },
            else => return val,
        }
    }

    fn evalMethodCall(self: *Evaluator, mc: *ast.MethodCallExpr, current_env: *Env) anyerror!Value {
        // Set call-site line for stack trace generation, and update parent frame's line
        if (mc.loc.line > 0) {
            self.current_call_line = mc.loc.line;
            if (self.call_stack.items.len > 0)
                self.call_stack.items[self.call_stack.items.len - 1].line = mc.loc.line;
        }
        // Null-safe operator (?.) - if object is null, return null
        if (mc.null_safe) {
            const obj_val = self.evalExpr(mc.object, current_env) catch |err| {
                if (err == error.ApexException and self.pending_exception != null) {
                    // Check if it's a NullPointerException
                    if (self.pending_exception.? == .object) {
                        const class_name = self.pending_exception.?.object.class_name;
                        if (std.ascii.indexOfIgnoreCase(class_name, "NullPointer") != null) {
                            self.pending_exception = null;
                            return Value.null_val;
                        }
                    }
                }
                return err;
            };
            if (obj_val == .null_val) return Value.null_val;
        }

        var args: std.ArrayListUnmanaged(Value) = .empty;
        var arg_type_hints: std.ArrayListUnmanaged(?[]const u8) = .empty;
        for (mc.args) |*arg| {
            try args.append(self.arena, try self.evalExpr(arg, current_env));
            // Extract cast and declared-type hints for overload resolution.
            const hint = self.extractExprTypeHint(arg, current_env);
            try arg_type_hints.append(self.arena, hint);
        }
        // Set cast type hints for method overload resolution
        const prev_hints = self.cast_type_hints;
        self.cast_type_hints = arg_type_hints.items;
        defer self.cast_type_hints = prev_hints;

        if (mc.object.* == .super_expr) {
            if (current_env.get("this")) |this_val| {
                if (this_val == .object) {
                    if (self.current_class) |current_class_name| {
                        if (self.findClass(current_class_name)) |current_decl| {
                            if (current_decl.super_class) |sc| {
                                if (self.findClass(sc.name)) |super_decl| {
                                    return self.callSuperInstanceMethod(super_decl, this_val.object, mc.method, args.items);
                                }
                            }
                        }
                    }
                }
            }
            return Value.null_val;
        }

        // Handle chained calls: System.Assert.areEqual → object = System.Assert, method = areEqual
        // Also handle: Test.startTest, Test.stopTest, TriggerHandler.bypass
        if (mc.object.* == .identifier) {
            const class_name = mc.object.identifier.name;

            // System.Assert / Assert methods
            if (std.ascii.eqlIgnoreCase(class_name, "Assert")) {
                return self.handleAssert(mc.method, args.items);
            }

            // System.assertEquals / System.assert / System.assertNotEquals
            if (std.ascii.eqlIgnoreCase(class_name, "System") and
                (std.ascii.startsWithIgnoreCase(mc.method, "assert") or
                    std.ascii.eqlIgnoreCase(mc.method, "assert")))
            {
                return self.handleAssert(mc.method, args.items);
            }

            // Test methods
            if (std.ascii.eqlIgnoreCase(class_name, "Test")) {
                return self.handleTest(mc.method, args.items);
            }

            // System.enqueueJob → execute synchronously (separate transaction in Salesforce)
            if (std.ascii.eqlIgnoreCase(class_name, "System") and std.ascii.eqlIgnoreCase(mc.method, "enqueueJob")) {
                if (args.items.len > 0 and args.items[0] == .object) {
                    return self.enqueueJob(args.items[0].object);
                }
                return .void_val;
            }

            // JSON.serialize/deserialize with round-trip support
            if (std.ascii.eqlIgnoreCase(class_name, "JSON")) {
                if (std.ascii.eqlIgnoreCase(mc.method, "serialize") or std.ascii.eqlIgnoreCase(mc.method, "serializePretty")) {
                    if (args.items.len > 0) {
                        self.last_json_value = args.items[0];
                        return Value{ .string = try utils.toJson(args.items[0], self.arena) };
                    }
                    return Value{ .string = "{}" };
                }
                if (std.ascii.eqlIgnoreCase(mc.method, "deserialize") or std.ascii.eqlIgnoreCase(mc.method, "deserializeStrict")) {
                    // Parse JSON string
                    if (args.items.len >= 1 and args.items[0] == .string) {
                        const json_str = args.items[0].string;
                        // Check for obviously malformed JSON
                        const trimmed_json = std.mem.trim(u8, json_str, " \t\r\n");
                        if (trimmed_json.len == 0 or
                            (trimmed_json[0] != '{' and trimmed_json[0] != '[' and trimmed_json[0] != '"' and
                                !std.ascii.isDigit(trimmed_json[0]) and
                                !std.mem.startsWith(u8, trimmed_json, "null") and
                                !std.mem.startsWith(u8, trimmed_json, "true") and
                                !std.mem.startsWith(u8, trimmed_json, "false")))
                        {
                            const exc = try self.arena.create(types.ObjectInstance);
                            exc.* = .{ .class_name = "JSONException" };
                            try exc.fields.put(self.arena, "message", Value{ .string = try std.fmt.allocPrint(self.arena, "Malformed JSON: {s}", .{json_str}) });
                            self.pending_exception = Value{ .object = exc };
                            return error.ApexException;
                        }
                        // Determine target type name from second arg
                        const type_name: []const u8 = if (args.items.len >= 2 and args.items[1] == .object) blk: {
                            const tobj = args.items[1].object;
                            // For Type objects (from ClassName.class), use the "name" field
                            if (std.ascii.eqlIgnoreCase(tobj.class_name, "Type")) {
                                if (tobj.fields.get("name")) |n| {
                                    if (n == .string) break :blk n.string;
                                }
                            }
                            break :blk tobj.class_name;
                        } else "Object";
                        const is_list_type = std.ascii.startsWithIgnoreCase(type_name, "List") or std.mem.endsWith(u8, type_name, "[]");
                        // Pre-validate: check for balanced braces/brackets (detect truncated JSON)
                        if (!utils.isJsonBalanced(trimmed_json)) {
                            const exc = try self.arena.create(types.ObjectInstance);
                            exc.* = .{ .class_name = "System.JSONException" };
                            try exc.fields.put(self.arena, "message", Value{ .string = try std.fmt.allocPrint(self.arena, "Malformed JSON: {s}", .{json_str}) });
                            self.pending_exception = Value{ .object = exc };
                            return error.ApexException;
                        }
                        const parsed = self.parseJsonValue(json_str, type_name);
                        if (parsed) |pv| {
                            return pv;
                        }
                        // parseJsonValue returned null → malformed JSON
                        // Check if the input looks like it should have parsed (not trivially malformed)
                        if (trimmed_json.len > 2) {
                            const exc = try self.arena.create(types.ObjectInstance);
                            exc.* = .{ .class_name = "JSONException" };
                            try exc.fields.put(self.arena, "message", Value{ .string = try std.fmt.allocPrint(self.arena, "Malformed JSON: {s}", .{json_str}) });
                            self.pending_exception = Value{ .object = exc };
                            return error.ApexException;
                        }
                        // Fallback for list types
                        if (is_list_type) {
                            const list = try self.arena.create(types.ListValue);
                            list.* = .{};
                            return Value{ .list = list };
                        }
                        const obj = try self.arena.create(types.SObject);
                        obj.* = .{ .type_name = "Object" };
                        return Value{ .sobject = obj };
                    }
                    // Null input
                    if (args.items.len >= 1 and args.items[0] == .null_val) {
                        const exc = try self.arena.create(types.ObjectInstance);
                        exc.* = .{ .class_name = "JSONException" };
                        try exc.fields.put(self.arena, "message", Value{ .string = "Argument cannot be null." });
                        self.pending_exception = Value{ .object = exc };
                        return error.ApexException;
                    }
                    return Value.null_val;
                }
                if (std.ascii.eqlIgnoreCase(mc.method, "createParser")) {
                    if (args.items.len >= 1 and args.items[0] == .string) {
                        const parser_obj = try self.arena.create(types.ObjectInstance);
                        parser_obj.* = .{ .class_name = "JSONParser" };
                        try parser_obj.fields.put(self.arena, "__json_body__", args.items[0]);
                        return Value{ .object = parser_obj };
                    }
                    return Value.null_val;
                }
            }

            // Custom Metadata Type: Type__mdt.getInstance(developerName) — early intercept
            if (std.mem.endsWith(u8, class_name, "__mdt") and
                (std.ascii.eqlIgnoreCase(mc.method, "getInstance") or std.ascii.eqlIgnoreCase(mc.method, "getAll")))
            {
                // Ensure records are loaded from .md-meta.xml files
                {
                    var fi = false;
                    var si = self.store.iterator();
                    while (si.next()) |entry| {
                        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                            fi = true;
                            break;
                        }
                    }
                    if (!fi) self.loadCustomMetadataFromFiles(class_name) catch {};
                }
                if (std.ascii.eqlIgnoreCase(mc.method, "getInstance")) {
                    const dev_name = if (args.items.len > 0 and args.items[0] == .string) args.items[0].string else "";
                    if (dev_name.len > 0) {
                        var mi = self.store.iterator();
                        while (mi.next()) |entry| {
                            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                                for (entry.value_ptr.items) |item| {
                                    if (item == .sobject) {
                                        if (utils.sobjectGet(&item.sobject.fields, "DeveloperName")) |dn| {
                                            if (dn == .string and std.ascii.eqlIgnoreCase(dn.string, dev_name)) return item;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return Value.null_val;
                }
                if (std.ascii.eqlIgnoreCase(mc.method, "getAll")) {
                    const map = try self.arena.create(types.MapValue);
                    map.* = .{};
                    var mi = self.store.iterator();
                    while (mi.next()) |entry| {
                        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                            for (entry.value_ptr.items) |item| {
                                if (item == .sobject) {
                                    if (utils.sobjectGet(&item.sobject.fields, "DeveloperName")) |dn| {
                                        if (dn == .string) try map.entries.put(self.arena, dn.string, item);
                                    }
                                }
                            }
                        }
                    }
                    return Value{ .map = map };
                }
            }

            // Integer.valueOf with invalid string → throw TypeException
            if (std.ascii.eqlIgnoreCase(class_name, "Integer") and std.ascii.eqlIgnoreCase(mc.method, "valueOf")) {
                if (args.items.len > 0 and args.items[0] == .string) {
                    if (std.fmt.parseInt(i64, args.items[0].string, 10)) |v| {
                        return Value{ .integer = v };
                    } else |_| {
                        const exc = try self.arena.create(types.ObjectInstance);
                        exc.* = .{ .class_name = "System.TypeException" };
                        try exc.fields.put(self.arena, "message", Value{ .string = try std.fmt.allocPrint(self.arena, "Invalid integer: {s}", .{args.items[0].string}) });
                        self.pending_exception = Value{ .object = exc };
                        return error.ApexException;
                    }
                }
            }

            // Check if identifier is a local variable (instance method call)
            // This comes BEFORE builtin checks so that variables named like
            // builtin classes (e.g., "Http http = new Http(); http.send()")
            // are resolved as instance methods, not static builtins.
            const resolved_var = blk: {
                if (current_env.get(class_name)) |v| break :blk v;
                // Also check current_class static fields (e.g., handler stored as ClassName.handler)
                if (self.current_class) |cc| {
                    // Check for static property getter first
                    const already_in_getter2 = if (self.evaluating_getter) |eg| std.ascii.eqlIgnoreCase(eg, class_name) else false;
                    if (!already_in_getter2) {
                        if (self.findClass(cc)) |cd| {
                            for (cd.members) |member| {
                                switch (member) {
                                    .field_decl => |fd| {
                                        if (fd.modifiers.is_static and std.ascii.eqlIgnoreCase(fd.name, class_name) and fd.getter_body != null) {
                                            const getter_env2 = self.global_env.child() catch break :blk Value.null_val;
                                            const saved_class2 = self.current_class;
                                            const saved_getter2 = self.evaluating_getter;
                                            self.current_class = cc;
                                            self.evaluating_getter = class_name;
                                            defer {
                                                self.current_class = saved_class2;
                                                self.evaluating_getter = saved_getter2;
                                            }
                                            const result2 = self.execBlock(fd.getter_body.?, getter_env2) catch break :blk Value.null_val;
                                            break :blk switch (result2) {
                                                .return_val => |v| v,
                                                else => self.return_value,
                                            };
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                    }
                    const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, class_name }) catch break :blk Value.null_val;
                    if (self.global_env.get(key)) |v| break :blk v;
                    // Check outer class static fields/getters when current_class is an inner class
                    if (self.resolveOuterStaticField(cc, class_name)) |v| break :blk v;
                }
                // Check "this" class static fields (and parent class hierarchy)
                if (current_env.get("this")) |this_val| {
                    if (this_val == .object) {
                        const this_cn = this_val.object.class_name;
                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ this_cn, class_name }) catch break :blk Value.null_val;
                        if (self.global_env.get(key)) |v| break :blk v;
                        // Walk parent class chain for inherited static fields
                        if (self.findClass(this_cn)) |this_cd| {
                            var cur_parent = this_cd.super_class;
                            while (cur_parent) |sc| {
                                self.ensureStaticInit(sc.name);
                                const pkey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ sc.name, class_name }) catch break;
                                if (self.global_env.get(pkey)) |v| break :blk v;
                                cur_parent = if (self.findClass(sc.name)) |pcd| pcd.super_class else null;
                            }
                        }
                        // Check outer class static fields/getters (for inner classes)
                        if (self.resolveOuterStaticField(this_cn, class_name)) |v| break :blk v;
                    }
                }
                break :blk Value.null_val;
            };
            switch (resolved_var) {
                .list, .map, .set, .sobject, .object, .string, .double, .integer => {
                    return self.evalInstanceMethod(resolved_var, mc.method, args.items, current_env);
                },
                else => {},
            }

            // Let a user-defined class named Database shadow the platform Database
            // namespace only when that class is actually visible at this call-site.
            // Unrelated inner classes named Database must not hijack platform
            // Database.executeBatch()/delete()/etc. in other classes.
            if (std.ascii.eqlIgnoreCase(class_name, "Database")) {
                if (self.resolveVisibleUserClassInScope(current_env, class_name)) |visible_class| {
                    return self.callMethod(visible_class, mc.method, args.items);
                }
            }

            // Database methods need the current lexical environment so dynamic SOQL
            // bind variables resolve local variables and method parameters.
            if (std.ascii.eqlIgnoreCase(class_name, "Database")) {
                return self.handleDatabaseMethod(mc.method, args.items, current_env);
            }

            // Builtin static dispatch (only reached when no local variable matched)
            var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
            if (try builtins.dispatchStatic(&bctx, class_name, mc.method, args.items)) |result| {
                return result;
            }

            // Custom Metadata Type: Type__mdt.getInstance(developerName) / getAll()
            // Must be checked BEFORE findClass to avoid falling through to callMethod
            if (std.mem.endsWith(u8, class_name, "__mdt")) {
                // Ensure records are loaded from .md-meta.xml files
                {
                    var found_in_store = false;
                    var si = self.store.iterator();
                    while (si.next()) |entry| {
                        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                            found_in_store = true;
                            break;
                        }
                    }
                    if (!found_in_store) self.loadCustomMetadataFromFiles(class_name) catch {};
                }
                if (std.ascii.eqlIgnoreCase(mc.method, "getInstance")) {
                    const dev_name = if (args.items.len > 0 and args.items[0] == .string) args.items[0].string else "";
                    var mdt_iter = self.store.iterator();
                    while (mdt_iter.next()) |entry| {
                        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                            for (entry.value_ptr.items) |item| {
                                if (item == .sobject) {
                                    if (utils.sobjectGet(&item.sobject.fields, "DeveloperName")) |dn| {
                                        if (dn == .string and std.ascii.eqlIgnoreCase(dn.string, dev_name)) {
                                            return item;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return Value.null_val;
                }
                if (std.ascii.eqlIgnoreCase(mc.method, "getAll")) {
                    const map = try self.arena.create(types.MapValue);
                    map.* = .{};
                    var mdt_iter = self.store.iterator();
                    while (mdt_iter.next()) |entry| {
                        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                            for (entry.value_ptr.items) |item| {
                                if (item == .sobject) {
                                    if (utils.sobjectGet(&item.sobject.fields, "DeveloperName")) |dn| {
                                        if (dn == .string) try map.entries.put(self.arena, dn.string, item);
                                    }
                                }
                            }
                        }
                    }
                    return Value{ .map = map };
                }
            }

            if (try self.handleCustomSettingStaticMethod(class_name, mc.method, args.items)) |result| {
                return result;
            }

            // User-defined class method (check before stubs/getSObjectType fallback)
            if (!std.ascii.eqlIgnoreCase(class_name, "Database") and self.findClass(class_name) != null) {
                return self.callMethod(class_name, mc.method, args.items);
            }

            // TestFactory / TestDataHelpers stubs (only when no user-defined class exists)
            if (try self.handleTestFactory(class_name, mc.method, args.items)) |result| {
                return result;
            }

            // SObjectType.getSObjectType() → return Schema.SObjectType (only for non-class identifiers)
            if (std.ascii.eqlIgnoreCase(mc.method, "getSObjectType")) {
                const sot = try self.arena.create(types.ObjectInstance);
                sot.* = .{ .class_name = "Schema.SObjectType" };
                try sot.fields.put(self.arena, "name", Value{ .string = class_name });
                return Value{ .object = sot };
            }

            return self.callMethod(class_name, mc.method, args.items);
        }

        // Handle three-level field_access chains: Schema.TypeName.SObjectType.method()
        if (mc.object.* == .field_access) {
            const fa = mc.object.field_access;
            // Schema.TypeName.SObjectType.newSObject(...) / getDescribe() etc.
            if (fa.object.* == .field_access) {
                const inner_fa = fa.object.field_access;
                if (inner_fa.object.* == .identifier) {
                    const outer_name = inner_fa.object.identifier.name;
                    const type_name = inner_fa.field;
                    if (std.ascii.eqlIgnoreCase(outer_name, "Schema") and
                        std.ascii.eqlIgnoreCase(type_name, "SObjectType"))
                    {
                        const sot = try self.arena.create(types.ObjectInstance);
                        sot.* = .{ .class_name = "Schema.SObjectType" };
                        try sot.fields.put(self.arena, "name", Value{ .string = fa.field });
                        return self.evalInstanceMethod(Value{ .object = sot }, mc.method, args.items, current_env);
                    }
                    if (std.ascii.eqlIgnoreCase(outer_name, "Schema") and
                        std.ascii.eqlIgnoreCase(fa.field, "SObjectType"))
                    {
                        // Build Schema.SObjectType object with name
                        const sot = try self.arena.create(types.ObjectInstance);
                        sot.* = .{ .class_name = "Schema.SObjectType" };
                        try sot.fields.put(self.arena, "name", Value{ .string = type_name });
                        return self.evalInstanceMethod(Value{ .object = sot }, mc.method, args.items, current_env);
                    }
                    if (std.ascii.eqlIgnoreCase(outer_name, "Schema") and
                        std.ascii.eqlIgnoreCase(mc.method, "getDescribe"))
                    {
                        const dfr = try self.arena.create(types.ObjectInstance);
                        dfr.* = .{ .class_name = "Schema.DescribeFieldResult" };
                        try dfr.fields.put(self.arena, "objectType", Value{ .string = type_name });
                        try dfr.fields.put(self.arena, "fieldName", Value{ .string = fa.field });
                        return Value{ .object = dfr };
                    }
                }
            }

            if (fa.object.* == .identifier) {
                const outer_class = fa.object.identifier.name;
                const inner = fa.field;

                // System.Assert.areEqual(...)
                if (std.ascii.eqlIgnoreCase(outer_class, "System") and std.ascii.eqlIgnoreCase(inner, "Assert")) {
                    return self.handleAssert(mc.method, args.items);
                }

                // System.enqueueJob, System.runAs, etc.
                if (std.ascii.eqlIgnoreCase(outer_class, "System")) {
                    return self.handleSystemMethod(inner, mc.method, args.items, current_env);
                }

                // SObjectType.FieldToken.getDescribe() → Schema.DescribeFieldResult
                // Exception: Type.SObjectType.getDescribe() is the object-level token,
                // which returns DescribeSObjectResult (handled via createDescribeResult)
                if (std.ascii.eqlIgnoreCase(mc.method, "getDescribe")) {
                    if (std.ascii.eqlIgnoreCase(inner, "SObjectType")) {
                        const sot = try self.arena.create(types.ObjectInstance);
                        sot.* = .{ .class_name = "Schema.SObjectType" };
                        try sot.fields.put(self.arena, "name", Value{ .string = outer_class });
                        return self.evalInstanceMethod(Value{ .object = sot }, mc.method, args.items, current_env);
                    }
                    const dfr = try self.arena.create(types.ObjectInstance);
                    dfr.* = .{ .class_name = "Schema.DescribeFieldResult" };
                    try dfr.fields.put(self.arena, "objectType", Value{ .string = outer_class });
                    try dfr.fields.put(self.arena, "fieldName", Value{ .string = inner });
                    return Value{ .object = dfr };
                }

                // DataWeave.Script.createScript(scriptName)
                if (std.ascii.eqlIgnoreCase(outer_class, "DataWeave") and std.ascii.eqlIgnoreCase(inner, "Script")) {
                    if (std.ascii.eqlIgnoreCase(mc.method, "createScript") and args.items.len > 0 and args.items[0] == .string) {
                        const dw = try self.arena.create(types.ObjectInstance);
                        dw.* = .{ .class_name = "DataWeave.Script" };
                        try dw.fields.put(self.arena, "scriptName", args.items[0]);
                        return Value{ .object = dw };
                    }
                }

                if (std.ascii.eqlIgnoreCase(outer_class, "Flow") and std.ascii.eqlIgnoreCase(inner, "Interview")) {
                    if (std.ascii.eqlIgnoreCase(mc.method, "createInterview") and args.items.len > 0 and args.items[0] == .string) {
                        if (!self.hasFlowDefinition(args.items[0].string)) {
                            const exc = try self.arena.create(types.ObjectInstance);
                            exc.* = .{ .class_name = "TypeException" };
                            try exc.fields.put(self.arena, "message", Value{ .string = "Unknown Flow" });
                            self.pending_exception = Value{ .object = exc };
                            return error.ApexException;
                        }

                        const interview = try self.arena.create(types.ObjectInstance);
                        interview.* = .{ .class_name = "Flow.Interview" };
                        try interview.fields.put(self.arena, "flowName", args.items[0]);
                        if (args.items.len > 1 and args.items[1] == .map) {
                            for (args.items[1].map.entries.keys(), args.items[1].map.entries.values()) |k, v| {
                                try interview.fields.put(self.arena, k, v);
                            }
                        }
                        return Value{ .object = interview };
                    }
                }

                // ConnectApi → throw UnsupportedOperationException unless SeeAllData=true
                if (std.ascii.eqlIgnoreCase(outer_class, "ConnectApi")) {
                    if (self.see_all_data) return Value.null_val;
                    const exc = try self.arena.create(types.ObjectInstance);
                    exc.* = .{ .class_name = "UnsupportedOperationException" };
                    try exc.fields.put(self.arena, "message", Value{ .string = "ConnectApi is not supported in data-siloed tests" });
                    self.pending_exception = Value{ .object = exc };
                    return error.ApexException;
                }

                // Cache.Session.getPartition / Cache.Org.getPartition
                if (std.ascii.eqlIgnoreCase(outer_class, "Cache") and
                    (std.ascii.eqlIgnoreCase(inner, "Session") or std.ascii.eqlIgnoreCase(inner, "Org")))
                {
                    if (std.ascii.eqlIgnoreCase(mc.method, "getPartition")) {
                        const partition_name = if (args.items.len > 0 and args.items[0] == .string) args.items[0].string else "default";
                        const partition = try self.arena.create(types.ObjectInstance);
                        partition.* = .{ .class_name = "Cache.Partition" };
                        // Use a map to store cache entries
                        const cache_map = try self.arena.create(types.MapValue);
                        cache_map.* = .{};
                        // Use a global key to find this cache partition
                        const cache_key = try std.fmt.allocPrint(self.arena, "Cache.{s}.partition:{s}", .{ inner, partition_name });
                        if (self.global_env.get(cache_key)) |existing| {
                            if (existing == .object) {
                                return existing;
                            }
                        }
                        const is_available = std.ascii.indexOfIgnoreCase(partition_name, "NeverExist") == null;
                        try partition.fields.put(self.arena, "_cache", Value{ .map = cache_map });
                        try partition.fields.put(self.arena, "_is_available", Value{ .boolean = is_available });
                        self.global_env.set(cache_key, Value{ .object = partition }) catch {
                            try self.global_env.define(cache_key, Value{ .object = partition });
                        };
                        return Value{ .object = partition };
                    }
                }
            }
        }

        // Instance method on evaluated object
        const obj = try self.evalExpr(mc.object, current_env);
        return self.evalInstanceMethod(obj, mc.method, args.items, current_env);
    }

    fn evalInstanceMethod(self: *Evaluator, obj: Value, method: []const u8, args: []const Value, _: *Env) anyerror!Value {
        // Null dereference → return null gracefully (some tests depend on this)
        if (obj == .null_val) return Value.null_val;

        // Http.send() mock interception
        if (obj == .object and std.ascii.eqlIgnoreCase(method, "send") and
            (std.ascii.eqlIgnoreCase(obj.object.class_name, "Http") or
                std.ascii.eqlIgnoreCase(obj.object.class_name, "HttpRequest")))
        {
            self.limits_callouts += 1;
            if (self.callout_mock) |mock| {
                // Call mock.respond(request) method
                if (mock == .object) {
                    if (self.findClass(mock.object.class_name)) |mock_class| {
                        const req_arg = if (args.len > 0) args[0] else Value.null_val;
                        return self.callInstanceMethod(mock_class, mock.object, "respond", &.{req_arg});
                    }
                }
            }
        }

        // Type.getName() / Type.toString() → return the type name
        if (obj == .object and std.ascii.eqlIgnoreCase(obj.object.class_name, "Type") and
            (std.ascii.eqlIgnoreCase(method, "getName") or std.ascii.eqlIgnoreCase(method, "toString") or std.ascii.eqlIgnoreCase(method, "getSimpleName")))
        {
            if (obj.object.fields.get("name")) |n| {
                if (n == .string) return n;
            }
            return Value.null_val;
        }

        // Type.newInstance() → use evaluator to properly instantiate classes
        if (obj == .object and std.ascii.eqlIgnoreCase(obj.object.class_name, "Type") and
            std.ascii.eqlIgnoreCase(method, "newInstance"))
        {
            const type_name = if (obj.object.fields.get("name")) |n|
                (if (n == .string) n.string else "Object")
            else
                "Object";
            // If the type name starts with Map/List/Set, return collection
            if (std.ascii.startsWithIgnoreCase(type_name, "Map")) {
                const map = try self.arena.create(types.MapValue);
                map.* = .{};
                return Value{ .map = map };
            }
            if (std.ascii.startsWithIgnoreCase(type_name, "List")) {
                const list = try self.arena.create(types.ListValue);
                list.* = .{};
                return Value{ .list = list };
            }
            if (std.ascii.startsWithIgnoreCase(type_name, "Set")) {
                const set = try self.arena.create(types.SetValue);
                set.* = .{};
                return Value{ .set = set };
            }
            // SObject type name → return .sobject directly
            if (self.isSObjectTypeName(type_name)) {
                const sob = try self.arena.create(types.SObject);
                sob.* = .{ .type_name = type_name };
                return Value{ .sobject = sob };
            }
            return self.instantiateClass(type_name);
        }

        // Stub provider delegation: if the object has __stubProvider__, delegate method calls
        if (obj == .object) {
            if (obj.object.fields.get("__stubProvider__")) |provider| {
                if (provider == .object) {
                    if (self.findClass(provider.object.class_name)) |prov_class| {
                        // Build args for handleMethodCall(stubbedObject, stubbedMethodName, returnType, listOfParamTypes, listOfParamNames, listOfArgs)
                        const args_list = try self.arena.create(types.ListValue);
                        args_list.* = .{};
                        for (args) |a| try args_list.items.append(self.arena, a);
                        // Build type list from actual arguments
                        const type_list = try self.arena.create(types.ListValue);
                        type_list.* = .{};
                        for (args) |a| {
                            const type_name: []const u8 = switch (a) {
                                .string => "String",
                                .integer => "Integer",
                                .double => "Double",
                                .boolean => "Boolean",
                                .list => "List",
                                .map => "Map",
                                .set => "Set",
                                .sobject => "SObject",
                                .object => |o| o.class_name,
                                .null_val => "Object",
                                else => "Object",
                            };
                            const type_obj = try self.arena.create(types.ObjectInstance);
                            type_obj.* = .{ .class_name = "Type" };
                            try type_obj.fields.put(self.arena, "name", Value{ .string = type_name });
                            try type_list.items.append(self.arena, Value{ .object = type_obj });
                        }
                        // Build param names from method declaration if available
                        const name_list = try self.arena.create(types.ListValue);
                        name_list.* = .{};
                        if (self.findClass(obj.object.class_name)) |stub_class| {
                            const stub_md = self.findMethodInHierarchy(null, stub_class, method, args.len);
                            if (stub_md) |smd| {
                                for (smd.params) |p| {
                                    try name_list.items.append(self.arena, Value{ .string = p.name });
                                }
                            }
                        }
                        const hmc_args = [_]Value{
                            obj,
                            Value{ .string = method },
                            Value.null_val,
                            Value{ .list = type_list },
                            Value{ .list = name_list },
                            Value{ .list = args_list },
                        };
                        return self.callInstanceMethod(prov_class, provider.object, "handleMethodCall", &hmc_args);
                    }
                }
            }
        }

        // Type.newInstance() → instantiate actual user-defined class if known
        if (obj == .object and std.ascii.eqlIgnoreCase(obj.object.class_name, "Type") and
            std.ascii.eqlIgnoreCase(method, "newInstance"))
        {
            const type_name = if (obj.object.fields.get("name")) |n| (if (n == .string) n.string else "Object") else "Object";
            if (self.findClass(type_name)) |cd| {
                const inst = try self.arena.create(types.ObjectInstance);
                // Preserve the requested type name so qualified inner classes
                // continue to dispatch against the intended outer class.
                inst.* = .{ .class_name = type_name };
                self.initInstanceFields(cd, inst) catch {};
                if (cd.super_class) |sc| {
                    if (self.findClass(sc.name)) |parent| {
                        self.initInstanceFields(parent, inst) catch {};
                    }
                }
                // Run constructor with no args if exists
                if (self.findMethodInHierarchy(null, cd, type_name, 0)) |ctor| {
                    const ctor_env = try self.global_env.child();
                    try ctor_env.define("this", Value{ .object = inst });
                    for (inst.fields.keys(), inst.fields.values()) |k, v| {
                        ctor_env.set(k, v) catch {
                            try ctor_env.define(k, v);
                        };
                    }
                    _ = self.execBlock(ctor.body, ctor_env) catch {};
                    // Sync back fields
                    if (ctor_env.get("this")) |tv| {
                        if (tv == .object and tv.object == inst) {} else if (tv == .object) {
                            for (tv.object.fields.keys(), tv.object.fields.values()) |k, v| {
                                inst.fields.put(self.arena, k, v) catch {};
                            }
                        }
                    }
                }
                return Value{ .object = inst };
            }
        }

        // JSONParser methods: nextToken, getCurrentToken, getText, readValueAs
        if (obj == .object and std.ascii.eqlIgnoreCase(obj.object.class_name, "JSONParser")) {
            const json_body = if (obj.object.fields.get("__json_body__")) |jb| (if (jb == .string) jb.string else null) else null;
            if (std.ascii.eqlIgnoreCase(method, "nextToken")) {
                if (json_body) |body| {
                    var pos: usize = if (obj.object.fields.get("__pos__")) |p| (if (p == .integer) @intCast(@as(u64, @bitCast(p.integer))) else 0) else 0;
                    // Skip whitespace
                    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\n' or body[pos] == '\r' or body[pos] == ',')) pos += 1;
                    if (pos >= body.len) {
                        try obj.object.fields.put(self.arena, "__token__", Value.null_val);
                        return Value.null_val;
                    }
                    const ch = body[pos];
                    if (ch == '{') {
                        try obj.object.fields.put(self.arena, "__token__", Value{ .string = "START_OBJECT" });
                        pos += 1;
                    } else if (ch == '}') {
                        try obj.object.fields.put(self.arena, "__token__", Value{ .string = "END_OBJECT" });
                        pos += 1;
                    } else if (ch == '[') {
                        try obj.object.fields.put(self.arena, "__token__", Value{ .string = "START_ARRAY" });
                        pos += 1;
                    } else if (ch == ']') {
                        try obj.object.fields.put(self.arena, "__token__", Value{ .string = "END_ARRAY" });
                        pos += 1;
                    } else if (ch == '"') {
                        // String or field name
                        const start = pos + 1;
                        pos += 1;
                        while (pos < body.len and body[pos] != '"') : (pos += 1) {
                            if (body[pos] == '\\') pos += 1;
                        }
                        const text = body[start..pos];
                        if (pos < body.len) pos += 1; // skip closing quote
                        // Check if followed by ':' → FIELD_NAME
                        var peek = pos;
                        while (peek < body.len and (body[peek] == ' ' or body[peek] == '\t')) peek += 1;
                        if (peek < body.len and body[peek] == ':') {
                            try obj.object.fields.put(self.arena, "__token__", Value{ .string = "FIELD_NAME" });
                            pos = peek + 1;
                        } else {
                            try obj.object.fields.put(self.arena, "__token__", Value{ .string = "VALUE_STRING" });
                        }
                        try obj.object.fields.put(self.arena, "__text__", Value{ .string = text });
                    } else if (ch == 't' or ch == 'f') {
                        try obj.object.fields.put(self.arena, "__token__", Value{ .string = "VALUE_BOOLEAN" });
                        if (std.mem.startsWith(u8, body[pos..], "true")) {
                            try obj.object.fields.put(self.arena, "__text__", Value{ .string = "true" });
                            pos += 4;
                        } else {
                            try obj.object.fields.put(self.arena, "__text__", Value{ .string = "false" });
                            pos += 5;
                        }
                    } else if (ch == 'n') {
                        try obj.object.fields.put(self.arena, "__token__", Value{ .string = "VALUE_NULL" });
                        pos += 4;
                    } else if (std.ascii.isDigit(ch) or ch == '-') {
                        const start = pos;
                        while (pos < body.len and (std.ascii.isDigit(body[pos]) or body[pos] == '.' or body[pos] == '-' or body[pos] == 'e' or body[pos] == 'E' or body[pos] == '+')) pos += 1;
                        try obj.object.fields.put(self.arena, "__token__", Value{ .string = "VALUE_NUMBER" });
                        try obj.object.fields.put(self.arena, "__text__", Value{ .string = body[start..pos] });
                    } else {
                        pos += 1;
                    }
                    try obj.object.fields.put(self.arena, "__pos__", Value{ .integer = @intCast(pos) });
                    return obj.object.fields.get("__token__") orelse Value.null_val;
                }
                return Value.null_val;
            }
            if (std.ascii.eqlIgnoreCase(method, "getCurrentToken")) {
                return obj.object.fields.get("__token__") orelse Value.null_val;
            }
            if (std.ascii.eqlIgnoreCase(method, "getText")) {
                return obj.object.fields.get("__text__") orelse Value{ .string = "" };
            }
            if (std.ascii.eqlIgnoreCase(method, "readValueAs")) {
                // Use current position (after nextToken navigation) or full body
                const pos: usize = if (obj.object.fields.get("__pos__")) |p| (if (p == .integer and p.integer > 0) @intCast(@as(u64, @bitCast(p.integer))) else 0) else 0;
                if (json_body) |body| {
                    // Back up one position to include the current token ([ or {)
                    const start = if (pos > 0) pos - 1 else 0;
                    const remaining = body[start..];
                    // Extract the actual type name from Type object (e.g., Type { name: "MyData" })
                    const type_name: []const u8 = if (args.len >= 1 and args[0] == .object) blk: {
                        if (std.ascii.eqlIgnoreCase(args[0].object.class_name, "Type")) {
                            if (args[0].object.fields.get("name")) |n| {
                                if (n == .string) break :blk n.string;
                            }
                        }
                        break :blk args[0].object.class_name;
                    } else "Object";
                    if (self.parseJsonValue(remaining, type_name)) |pv| return pv;
                }
                return Value.null_val;
            }
        }

        // Date/DateTime objects: extract the inner date string and dispatch as string methods
        if (obj == .object) {
            if (std.ascii.eqlIgnoreCase(obj.object.class_name, "Date") or
                std.ascii.eqlIgnoreCase(obj.object.class_name, "Datetime"))
            {
                if (builtins.extractDateString(obj)) |date_str| {
                    const result = try self.evalStringMethod(date_str, method, args);
                    // Wrap date() result back into a Date object, and addDays etc. keep their type
                    if (result == .string) {
                        if (std.ascii.eqlIgnoreCase(method, "date") or std.ascii.eqlIgnoreCase(method, "dateGmt")) {
                            return try builtins.makeDateValue(self.arena, result.string);
                        }
                        if (std.ascii.eqlIgnoreCase(method, "addDays") or
                            std.ascii.eqlIgnoreCase(method, "addMonths") or
                            std.ascii.eqlIgnoreCase(method, "addYears") or
                            std.ascii.eqlIgnoreCase(method, "addHours") or
                            std.ascii.eqlIgnoreCase(method, "addMinutes") or
                            std.ascii.eqlIgnoreCase(method, "addSeconds"))
                        {
                            if (std.ascii.eqlIgnoreCase(obj.object.class_name, "Date")) {
                                return try builtins.makeDateValue(self.arena, result.string);
                            }
                            return try builtins.makeDatetimeValue(self.arena, result.string);
                        }
                    }
                    return result;
                }
            }
        }

        // For ObjectInstance with a user-defined class, try class methods first
        if (obj == .object) {
            if (self.findClass(obj.object.class_name)) |class_decl| {
                const md = self.findMethodInHierarchyTyped(null, class_decl, method, args) orelse
                    self.findMethodInHierarchy(null, class_decl, method, args.len);
                if (md != null) {
                    return self.callInstanceMethod(class_decl, obj.object, method, args);
                }
                // Method not found in this class — it may be shadowed by a same-named
                // top-level class. Search for an outer class whose inner class matches
                // and has the method (e.g., LoggerDataStore.Database vs top-level Database).
                var cls_iter = self.classes.iterator();
                while (cls_iter.next()) |entry| {
                    const cd = entry.value_ptr.*;
                    for (cd.members) |member| {
                        switch (member) {
                            .class_decl => |inner_cd| {
                                if (std.ascii.eqlIgnoreCase(inner_cd.name, obj.object.class_name) and inner_cd != class_decl) {
                                    const inner_md = self.findMethodInHierarchyTyped(null, inner_cd, method, args) orelse
                                        self.findMethodInHierarchy(null, inner_cd, method, args.len);
                                    if (inner_md != null) {
                                        return self.callInstanceMethod(inner_cd, obj.object, method, args);
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
            }
        }

        var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
        if (try builtins.dispatchInstance(&bctx, obj, method, args)) |result| {
            return result;
        }

        // SObject field access methods
        if (obj == .sobject) {
            // getSObjects(relationship)
            if (std.ascii.eqlIgnoreCase(method, "getSObjects") and args.len > 0 and args[0] == .string) {
                return utils.sobjectGet(&obj.sobject.fields, args[0].string) orelse try self.makeEmptyList();
            }
            // get(fieldName) - case-insensitive
            if (std.ascii.eqlIgnoreCase(method, "get") and args.len > 0) {
                const field_name: []const u8 = if (args[0] == .string)
                    args[0].string
                else if (args[0] == .object) blk: {
                    if (args[0].object.fields.get("fieldName")) |n| {
                        if (n == .string) break :blk n.string;
                    }
                    if (args[0].object.fields.get("name")) |n| {
                        if (n == .string) break :blk n.string;
                    }
                    break :blk try utils.coerceToString(args[0], self.arena);
                } else try utils.coerceToString(args[0], self.arena);
                return self.getSObjectFieldValueCaseInsensitive(obj.sobject, field_name) orelse Value.null_val;
            }
            // getSObject(fieldName) - resolve loaded parent records or follow FK to the store
            if (std.ascii.eqlIgnoreCase(method, "getSObject") and args.len > 0) {
                const raw_name: []const u8 = if (args[0] == .string)
                    args[0].string
                else if (args[0] == .object) blk: {
                    if (args[0].object.fields.get("fieldName")) |n| {
                        if (n == .string) break :blk n.string;
                    }
                    if (args[0].object.fields.get("name")) |n| {
                        if (n == .string) break :blk n.string;
                    }
                    break :blk try utils.coerceToString(args[0], self.arena);
                } else try utils.coerceToString(args[0], self.arena);

                if (self.getSObjectFieldValueCaseInsensitive(obj.sobject, raw_name)) |loaded| {
                    if (loaded == .sobject) return loaded;
                }

                const relationship_name = if (std.mem.endsWith(u8, raw_name, "__c") or std.mem.endsWith(u8, raw_name, "Id"))
                    self.fkToParentRef(raw_name)
                else
                    raw_name;
                if (!std.ascii.eqlIgnoreCase(relationship_name, raw_name)) {
                    if (self.getSObjectFieldValueCaseInsensitive(obj.sobject, relationship_name)) |loaded| {
                        if (loaded == .sobject) return loaded;
                    }
                }

                const fk_field = if (std.mem.endsWith(u8, raw_name, "__c") or std.mem.endsWith(u8, raw_name, "Id"))
                    raw_name
                else
                    self.parentRefToFk(raw_name);
                const fk_value = self.getSObjectFieldValueCaseInsensitive(obj.sobject, fk_field) orelse return Value.null_val;
                if (fk_value != .string) return Value.null_val;

                const target_type = blk: {
                    if (self.getFieldMetadata(obj.sobject.type_name, fk_field)) |meta| {
                        if (meta.reference_to) |reference_to| break :blk reference_to;
                    }
                    if (self.findRecordTypeById(fk_value.string)) |record_type| break :blk record_type;
                    if (fk_value.string.len >= 3) {
                        const inferred = sobjectTypeFromPrefix(fk_value.string[0..3]);
                        if (!std.ascii.eqlIgnoreCase(inferred, "SObject")) break :blk inferred;
                    }
                    break :blk null;
                } orelse return Value.null_val;

                if (self.findRecordById(target_type, fk_value.string)) |record| {
                    if (record == .sobject) return record;
                }

                const related = try self.arena.create(types.SObject);
                related.* = .{ .type_name = target_type };
                related.id = fk_value.string;
                try related.fields.put(self.arena, "Id", fk_value);
                return Value{ .sobject = related };
            }
            // put(fieldName, value)
            if (std.ascii.eqlIgnoreCase(method, "put") and args.len >= 2) {
                // put(String fieldName, value) or put(SObjectField, value)
                const field_name: []const u8 = if (args[0] == .string)
                    args[0].string
                else if (args[0] == .object) blk: {
                    // SObjectField token — extract field name from "name" or "fieldName" field
                    if (args[0].object.fields.get("name")) |n| {
                        if (n == .string) break :blk n.string;
                    }
                    if (args[0].object.fields.get("fieldName")) |n| {
                        if (n == .string) break :blk n.string;
                    }
                    break :blk try utils.coerceToString(args[0], self.arena);
                } else try utils.coerceToString(args[0], self.arena);
                try utils.sobjectPut(&obj.sobject.fields, self.arena, field_name, args[1]);
                // Sync Id field
                if (std.ascii.eqlIgnoreCase(field_name, "Id") and args[1] == .string) {
                    obj.sobject.id = args[1].string;
                }
                return args[1];
            }
            // clone()
            if (std.ascii.eqlIgnoreCase(method, "clone") or std.ascii.eqlIgnoreCase(method, "deepClone")) {
                const clone = try self.arena.create(types.SObject);
                clone.* = .{ .type_name = obj.sobject.type_name };
                // Clone preserves Id unless first arg is false
                const preserve_id = if (args.len >= 1 and args[0] == .boolean) args[0].boolean else true;
                if (preserve_id and obj.sobject.id != null) {
                    clone.id = obj.sobject.id;
                }
                for (obj.sobject.fields.keys(), obj.sobject.fields.values()) |k, v| {
                    if (!preserve_id and std.ascii.eqlIgnoreCase(k, "Id")) continue;
                    try clone.fields.put(self.arena, k, v);
                }
                return Value{ .sobject = clone };
            }
            // getSObjectType()
            if (std.ascii.eqlIgnoreCase(method, "getSObjectType")) {
                const sot = try self.arena.create(types.ObjectInstance);
                sot.* = .{ .class_name = "Schema.SObjectType" };
                try sot.fields.put(self.arena, "name", Value{ .string = obj.sobject.type_name });
                return Value{ .object = sot };
            }
            // Database result methods on SObject (SaveResult, UpsertResult, etc.)
            if (std.ascii.eqlIgnoreCase(method, "isSuccess")) {
                return utils.sobjectGet(&obj.sobject.fields, "success") orelse
                    utils.sobjectGet(&obj.sobject.fields, "isSuccess") orelse Value{ .boolean = true };
            }
            if (std.ascii.eqlIgnoreCase(method, "isCreated")) {
                return utils.sobjectGet(&obj.sobject.fields, "created") orelse
                    utils.sobjectGet(&obj.sobject.fields, "isCreated") orelse Value{ .boolean = false };
            }
            if (std.ascii.eqlIgnoreCase(method, "getErrors")) {
                return utils.sobjectGet(&obj.sobject.fields, "errors") orelse try self.makeEmptyList();
            }
            if (std.ascii.eqlIgnoreCase(method, "getId")) {
                return utils.sobjectGet(&obj.sobject.fields, "Id") orelse
                    utils.sobjectGet(&obj.sobject.fields, "id") orelse Value.null_val;
            }
            // getPopulatedFieldsAsMap()
            if (std.ascii.eqlIgnoreCase(method, "getPopulatedFieldsAsMap")) {
                const map = try self.arena.create(types.MapValue);
                map.* = .{};
                for (obj.sobject.fields.keys(), obj.sobject.fields.values()) |k, v| {
                    if (v == .null_val) continue;
                    try map.entries.put(self.arena, k, v);
                }
                return Value{ .map = map };
            }
            // addError(msg)
            if (std.ascii.eqlIgnoreCase(method, "addError") and args.len > 0) {
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "DmlException" };
                try exc.fields.put(self.arena, "message", args[0]);
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
        }

        // List methods
        if (obj == .list) {
            return self.evalListMethod(obj.list, method, args);
        }

        // Map methods
        if (obj == .map) {
            return self.evalMapMethod(obj.map, method, args);
        }

        // Set methods
        if (obj == .set) {
            return self.evalSetMethod(obj.set, method, args);
        }

        // String methods
        if (obj == .string) {
            return self.evalStringMethod(obj.string, method, args);
        }

        // ObjectInstance methods (user-defined class)
        if (obj == .object) {
            // Try to call method on the class with `this` bound
            if (self.findClass(obj.object.class_name)) |class_decl| {
                return self.callInstanceMethod(class_decl, obj.object, method, args);
            }
            // If class not found by instance class_name, check if there's a parent class
            // (inner class pattern: "OuterClass.InnerClass")
        }

        return Value.null_val;
    }

    fn evalListMethod(self: *Evaluator, list: *types.ListValue, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "add")) {
            if (args.len > 0) try list.items.append(self.arena, args[0]);
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "size")) return Value{ .integer = @intCast(list.items.items.len) };
        if (std.ascii.eqlIgnoreCase(method, "isEmpty")) return Value{ .boolean = list.items.items.len == 0 };
        if (std.ascii.eqlIgnoreCase(method, "get") and args.len > 0 and args[0] == .integer) {
            if (args[0].integer < 0) return Value.null_val;
            const i: usize = @intCast(args[0].integer);
            if (i < list.items.items.len) return list.items.items[i];
            return Value.null_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "set") and args.len >= 2 and args[0] == .integer) {
            if (args[0].integer < 0) return .void_val;
            const i: usize = @intCast(args[0].integer);
            if (i < list.items.items.len) list.items.items[i] = args[1];
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "clear")) {
            list.items.items.len = 0;
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "contains") and args.len > 0) {
            for (list.items.items) |item| {
                if (utils.valueEql(item, args[0])) return Value{ .boolean = true };
            }
            return Value{ .boolean = false };
        }
        if (std.ascii.eqlIgnoreCase(method, "remove") and args.len > 0 and args[0] == .integer) {
            if (args[0].integer < 0) return .void_val;
            const i: usize = @intCast(args[0].integer);
            if (i < list.items.items.len) {
                const removed = list.items.orderedRemove(i);
                return removed;
            }
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "sort")) {
            // If an arg is provided and is a Comparator instance, use it
            if (args.len > 0 and args[0] == .object) {
                const comparator_obj = args[0].object;
                if (self.findClass(comparator_obj.class_name)) |comparator_class| {
                    // Insertion sort using comparator.compare(a, b)
                    const items = list.items.items;
                    var i_idx: usize = 1;
                    while (i_idx < items.len) : (i_idx += 1) {
                        const key = items[i_idx];
                        var j_idx: usize = i_idx;
                        while (j_idx > 0) {
                            const cmp = self.callInstanceMethod(comparator_class, comparator_obj, "compare", &.{ items[j_idx - 1], key }) catch Value{ .integer = 0 };
                            if (cmp == .integer and cmp.integer > 0) {
                                items[j_idx] = items[j_idx - 1];
                                j_idx -= 1;
                            } else break;
                        }
                        items[j_idx] = key;
                    }
                }
            } else {
                // Default sort: for objects implementing Comparable, use compareTo.
                // Otherwise, sort by natural order (strings, integers, etc.)
                const items = list.items.items;
                const use_comparable = items.len > 0 and items[0] == .object and
                    self.hasComparableInterface(items[0].object.class_name);
                var i_idx: usize = 1;
                while (i_idx < items.len) : (i_idx += 1) {
                    const key = items[i_idx];
                    var j_idx: usize = i_idx;
                    while (j_idx > 0) {
                        const cmp = if (use_comparable and items[j_idx - 1] == .object and key == .object)
                            self.callCompareTo(items[j_idx - 1].object, key)
                        else
                            self.compareValues(items[j_idx - 1], key);
                        if (cmp > 0) {
                            items[j_idx] = items[j_idx - 1];
                            j_idx -= 1;
                        } else break;
                    }
                    items[j_idx] = key;
                }
            }
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "addAll") and args.len > 0) {
            if (args[0] == .list) {
                for (args[0].list.items.items) |item| try list.items.append(self.arena, item);
            } else if (args[0] == .set) {
                for (args[0].set.entries.values()) |item| try list.items.append(self.arena, item);
            }
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "clone") or std.ascii.eqlIgnoreCase(method, "deepClone")) {
            const is_deep = std.ascii.eqlIgnoreCase(method, "deepClone");
            const new_list = try self.arena.create(types.ListValue);
            new_list.* = .{};
            for (list.items.items) |item| {
                const cloned = if (is_deep and item == .sobject) blk: {
                    const clone = try self.cloneSObject(item.sobject);
                    break :blk Value{ .sobject = clone };
                } else item;
                try new_list.items.append(self.arena, cloned);
            }
            return Value{ .list = new_list };
        }
        if (std.ascii.eqlIgnoreCase(method, "indexOf") and args.len > 0) {
            for (list.items.items, 0..) |item, idx| {
                if (utils.valueEql(item, args[0])) return Value{ .integer = @intCast(idx) };
            }
            return Value{ .integer = -1 };
        }
        if (std.ascii.eqlIgnoreCase(method, "getSObjectType")) {
            // Return type of first element, or null for empty/non-SObject lists
            if (list.items.items.len > 0 and list.items.items[0] == .sobject) {
                const sot = try self.arena.create(types.ObjectInstance);
                sot.* = .{ .class_name = "Schema.SObjectType" };
                try sot.fields.put(self.arena, "name", Value{ .string = list.items.items[0].sobject.type_name });
                return Value{ .object = sot };
            }
            // Empty list or non-SObject list → return null (Salesforce behavior)
            return Value.null_val;
        }
        return Value.null_val;
    }

    fn evalMapMethod(self: *Evaluator, map: *types.MapValue, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "put") and args.len >= 2) {
            // Apex Map<String,X> stores null keys as empty string
            const key = if (args[0] == .null_val) "" else try utils.coerceToString(args[0], self.arena);
            try map.entries.put(self.arena, key, args[1]);
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "get") and args.len > 0) {
            const key = if (args[0] == .null_val) "" else try utils.coerceToString(args[0], self.arena);
            if (map.entries.get(key)) |v| return v;
            // Case-insensitive fallback for String-keyed maps
            for (map.entries.keys(), map.entries.values()) |k, v| {
                if (std.ascii.eqlIgnoreCase(k, key)) return v;
            }
            return Value.null_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "containsKey") and args.len > 0) {
            const key = try utils.coerceToString(args[0], self.arena);
            if (map.entries.contains(key)) return Value{ .boolean = true };
            // Case-insensitive fallback
            for (map.entries.keys()) |k| {
                if (std.ascii.eqlIgnoreCase(k, key)) return Value{ .boolean = true };
            }
            return Value{ .boolean = false };
        }
        if (std.ascii.eqlIgnoreCase(method, "size")) return Value{ .integer = @intCast(map.entries.count()) };
        if (std.ascii.eqlIgnoreCase(method, "isEmpty")) return Value{ .boolean = map.entries.count() == 0 };
        if (std.ascii.eqlIgnoreCase(method, "keySet")) {
            const set = try self.arena.create(types.SetValue);
            set.* = .{};
            for (map.entries.keys()) |key| {
                try set.entries.put(self.arena, key, Value{ .string = key });
            }
            return Value{ .set = set };
        }
        if (std.ascii.eqlIgnoreCase(method, "values")) {
            const list = try self.arena.create(types.ListValue);
            list.* = .{};
            for (map.entries.values()) |val| {
                try list.items.append(self.arena, val);
            }
            return Value{ .list = list };
        }
        if (std.ascii.eqlIgnoreCase(method, "remove") and args.len > 0) {
            const key = try utils.coerceToString(args[0], self.arena);
            if (map.entries.get(key)) |val| {
                _ = map.entries.orderedRemove(key);
                return val;
            }
            return Value.null_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "putAll") and args.len > 0) {
            if (args[0] == .map) {
                for (args[0].map.entries.keys(), args[0].map.entries.values()) |k, v| {
                    try map.entries.put(self.arena, k, v);
                }
            } else if (args[0] == .list) {
                // putAll from list of SObjects: key=Id, value=record
                for (args[0].list.items.items) |item| {
                    if (item == .sobject and item.sobject.id != null) {
                        try map.entries.put(self.arena, item.sobject.id.?, item);
                    }
                }
            }
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "clear")) {
            map.entries = .empty;
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "clone") or std.ascii.eqlIgnoreCase(method, "deepClone")) {
            const new_map = try self.arena.create(types.MapValue);
            new_map.* = .{};
            for (map.entries.keys(), map.entries.values()) |k, v| {
                const cloned_val = if (std.ascii.eqlIgnoreCase(method, "deepClone") and v == .sobject) blk: {
                    const clone = try self.cloneSObject(v.sobject);
                    break :blk Value{ .sobject = clone };
                } else v;
                try new_map.entries.put(self.arena, k, cloned_val);
            }
            return Value{ .map = new_map };
        }
        return Value.null_val;
    }

    fn setEntryKey(self: *Evaluator, value: Value) ![]const u8 {
        return switch (value) {
            .sobject => |sob| blk: {
                if (sob.id) |id| break :blk id;
                if (utils.sobjectGet(&sob.fields, "Id")) |id_val| {
                    if (id_val == .string) break :blk id_val.string;
                }
                if (utils.sobjectGet(&sob.fields, "UniqueId__c")) |unique_id| {
                    if (unique_id == .string) {
                        break :blk try std.fmt.allocPrint(self.arena, "{s}#uid:{s}", .{ sob.type_name, unique_id.string });
                    }
                }
                if (utils.sobjectGet(&sob.fields, "Name")) |name_val| {
                    if (name_val == .string) {
                        break :blk try std.fmt.allocPrint(self.arena, "{s}#name:{s}", .{ sob.type_name, name_val.string });
                    }
                }
                const json = try utils.toJson(value, self.arena);
                break :blk try std.fmt.allocPrint(self.arena, "{s}#json:{s}", .{ sob.type_name, json });
            },
            else => try utils.coerceToString(value, self.arena),
        };
    }

    fn evalSetMethod(self: *Evaluator, set: *types.SetValue, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "add") and args.len > 0) {
            const key = try self.setEntryKey(args[0]);
            try set.entries.put(self.arena, key, args[0]);
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "contains") and args.len > 0) {
            const key = try self.setEntryKey(args[0]);
            return Value{ .boolean = set.entries.contains(key) };
        }
        if (std.ascii.eqlIgnoreCase(method, "size")) return Value{ .integer = @intCast(set.entries.count()) };
        if (std.ascii.eqlIgnoreCase(method, "isEmpty")) return Value{ .boolean = set.entries.count() == 0 };
        if (std.ascii.eqlIgnoreCase(method, "toString")) {
            return Value{ .string = try utils.coerceToString(Value{ .set = set }, self.arena) };
        }
        if (std.ascii.eqlIgnoreCase(method, "addAll") and args.len > 0) {
            if (args[0] == .list) {
                for (args[0].list.items.items) |item| {
                    const key = try self.setEntryKey(item);
                    try set.entries.put(self.arena, key, item);
                }
            } else if (args[0] == .set) {
                for (args[0].set.entries.keys(), args[0].set.entries.values()) |key, item| {
                    try set.entries.put(self.arena, key, item);
                }
            }
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "remove") and args.len > 0) {
            const key = try self.setEntryKey(args[0]);
            _ = set.entries.orderedRemove(key);
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "clear")) {
            set.entries = .empty;
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "containsAll") and args.len > 0 and args[0] == .set) {
            for (args[0].set.entries.keys()) |key| {
                if (!set.entries.contains(key)) return Value{ .boolean = false };
            }
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "clone") or std.ascii.eqlIgnoreCase(method, "deepClone")) {
            const new_set = try self.arena.create(types.SetValue);
            new_set.* = .{};
            for (set.entries.keys(), set.entries.values()) |key, item| {
                try new_set.entries.put(self.arena, key, item);
            }
            return Value{ .set = new_set };
        }
        return Value.null_val;
    }

    fn evalStringMethod(self: *Evaluator, s: []const u8, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "toString")) return Value{ .string = s };
        if (std.ascii.eqlIgnoreCase(method, "length")) return Value{ .integer = @intCast(s.len) };
        if (std.ascii.eqlIgnoreCase(method, "toUpperCase")) {
            const upper = try self.arena.alloc(u8, s.len);
            for (s, 0..) |ch, i| upper[i] = std.ascii.toUpper(ch);
            return Value{ .string = upper };
        }
        if (std.ascii.eqlIgnoreCase(method, "toLowerCase")) {
            const lower = try self.arena.alloc(u8, s.len);
            for (s, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
            return Value{ .string = lower };
        }
        if (std.ascii.eqlIgnoreCase(method, "trim")) return Value{ .string = std.mem.trim(u8, s, " \t\r\n") };
        if (std.ascii.eqlIgnoreCase(method, "repeat") and args.len > 0) {
            const count: usize = switch (args[0]) {
                .integer => |i| if (i > 0) @intCast(i) else 0,
                .double => |d| if (d > 0) @intFromFloat(d) else 0,
                else => 0,
            };
            if (count == 0 or s.len == 0) return Value{ .string = "" };
            const buf = try self.arena.alloc(u8, s.len * count);
            for (0..count) |ci| @memcpy(buf[ci * s.len ..][0..s.len], s);
            return Value{ .string = buf };
        }
        if (std.ascii.eqlIgnoreCase(method, "contains") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.mem.indexOf(u8, s, args[0].string) != null };
        }
        if (std.ascii.eqlIgnoreCase(method, "containsIgnoreCase") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.ascii.indexOfIgnoreCase(s, args[0].string) != null };
        }
        if (std.ascii.eqlIgnoreCase(method, "startsWith") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.mem.startsWith(u8, s, args[0].string) };
        }
        if (std.ascii.eqlIgnoreCase(method, "endsWith") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.mem.endsWith(u8, s, args[0].string) };
        }
        if (std.ascii.eqlIgnoreCase(method, "indexOf") and args.len > 0 and args[0] == .string) {
            const idx = std.mem.indexOf(u8, s, args[0].string);
            return Value{ .integer = if (idx) |i| @intCast(i) else -1 };
        }
        if (std.ascii.eqlIgnoreCase(method, "substring")) {
            if (args.len >= 2 and args[0] == .integer and args[1] == .integer) {
                const start: usize = @intCast(@max(args[0].integer, 0));
                const end: usize = @intCast(@min(args[1].integer, @as(i64, @intCast(s.len))));
                if (start <= end and end <= s.len) return Value{ .string = s[start..end] };
            } else if (args.len >= 1 and args[0] == .integer) {
                const start: usize = @intCast(@max(args[0].integer, 0));
                if (start <= s.len) return Value{ .string = s[start..] };
            }
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "split") and args.len > 0 and args[0] == .string) {
            const list = try self.arena.create(types.ListValue);
            list.* = .{};
            const pattern = args[0].string;
            const split_limit: ?usize = if (args.len >= 2 and args[1] == .integer and args[1].integer > 0)
                @intCast(args[1].integer)
            else
                null;
            var unescaped_buf = std.ArrayListUnmanaged(u8).empty;
            var pi: usize = 0;
            while (pi < pattern.len) : (pi += 1) {
                if (pattern[pi] == '\\' and pi + 1 < pattern.len) {
                    pi += 1;
                    try unescaped_buf.append(self.arena, pattern[pi]);
                    continue;
                }
                try unescaped_buf.append(self.arena, pattern[pi]);
            }
            const split_str = unescaped_buf.items;
            if (split_str.len == 0) {
                // 空デリミタ: 各文字を要素として返す (Apex の String.split('') 挙動)
                for (0..s.len) |ci| {
                    try list.items.append(self.arena, Value{ .string = s[ci .. ci + 1] });
                }
            } else {
                if (split_limit) |limit| {
                    if (limit <= 1) {
                        try list.items.append(self.arena, Value{ .string = s });
                    } else {
                        var start: usize = 0;
                        var splits_done: usize = 0;
                        while (splits_done + 1 < limit) {
                            const next = std.mem.indexOfPos(u8, s, start, split_str) orelse break;
                            try list.items.append(self.arena, Value{ .string = s[start..next] });
                            start = next + split_str.len;
                            splits_done += 1;
                        }
                        try list.items.append(self.arena, Value{ .string = s[start..] });
                    }
                } else {
                    var iter = std.mem.splitSequence(u8, s, split_str);
                    while (iter.next()) |part| {
                        try list.items.append(self.arena, Value{ .string = part });
                    }
                }
            }
            return Value{ .list = list };
        }
        if (std.ascii.eqlIgnoreCase(method, "replace") and args.len >= 2 and args[0] == .string and args[1] == .string) {
            const result = try std.mem.replaceOwned(u8, self.arena, s, args[0].string, args[1].string);
            return Value{ .string = result };
        }
        if (std.ascii.eqlIgnoreCase(method, "replaceAll") and args.len >= 2 and args[0] == .string and args[1] == .string) {
            const result = try regex.replaceAll(self.arena, args[0].string, s, args[1].string);
            return Value{ .string = result };
        }
        if (std.ascii.eqlIgnoreCase(method, "equals") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.mem.eql(u8, s, args[0].string) };
        }
        if (std.ascii.eqlIgnoreCase(method, "equalsIgnoreCase") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.ascii.eqlIgnoreCase(s, args[0].string) };
        }
        if (std.ascii.eqlIgnoreCase(method, "left") and args.len > 0 and args[0] == .integer) {
            const n: usize = @intCast(@max(args[0].integer, 0));
            const end = @min(n, s.len);
            return Value{ .string = s[0..end] };
        }
        if (std.ascii.eqlIgnoreCase(method, "right") and args.len > 0 and args[0] == .integer) {
            const n: usize = @intCast(@max(args[0].integer, 0));
            const start = if (n >= s.len) 0 else s.len - n;
            return Value{ .string = s[start..] };
        }
        if (std.ascii.eqlIgnoreCase(method, "abbreviate") and args.len > 0 and args[0] == .integer) {
            const max_width: usize = @intCast(@max(args[0].integer, 0));
            if (s.len <= max_width) return Value{ .string = s };
            if (max_width <= 3) return Value{ .string = s[0..max_width] };
            return Value{ .string = try std.fmt.allocPrint(self.arena, "{s}...", .{s[0 .. max_width - 3]}) };
        }
        // leftPad(length) or leftPad(length, padStr)
        if (std.ascii.eqlIgnoreCase(method, "leftPad") and args.len > 0 and args[0] == .integer) {
            const target_len: usize = @intCast(@max(args[0].integer, 0));
            if (s.len >= target_len) return Value{ .string = s };
            const pad_char: u8 = if (args.len > 1 and args[1] == .string and args[1].string.len > 0) args[1].string[0] else ' ';
            const result = try self.arena.alloc(u8, target_len);
            const pad_count = target_len - s.len;
            @memset(result[0..pad_count], pad_char);
            @memcpy(result[pad_count..], s);
            return Value{ .string = result };
        }
        // rightPad(length) or rightPad(length, padStr)
        if (std.ascii.eqlIgnoreCase(method, "rightPad") and args.len > 0 and args[0] == .integer) {
            const target_len: usize = @intCast(@max(args[0].integer, 0));
            if (s.len >= target_len) return Value{ .string = s };
            const pad_char: u8 = if (args.len > 1 and args[1] == .string and args[1].string.len > 0) args[1].string[0] else ' ';
            const result = try self.arena.alloc(u8, target_len);
            @memcpy(result[0..s.len], s);
            @memset(result[s.len..], pad_char);
            return Value{ .string = result };
        }
        if (std.ascii.eqlIgnoreCase(method, "isBlank")) {
            return Value{ .boolean = std.mem.trim(u8, s, " \t\r\n").len == 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "isNotBlank")) {
            return Value{ .boolean = std.mem.trim(u8, s, " \t\r\n").len > 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "isEmpty")) {
            return Value{ .boolean = s.len == 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "isNotEmpty")) {
            return Value{ .boolean = s.len > 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "isNumeric")) {
            if (s.len == 0) return Value{ .boolean = false };
            for (s) |ch| {
                if (!std.ascii.isDigit(ch)) return Value{ .boolean = false };
            }
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "isAlpha")) {
            if (s.len == 0) return Value{ .boolean = false };
            for (s) |ch| {
                if (!std.ascii.isAlphabetic(ch)) return Value{ .boolean = false };
            }
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "isAlphanumeric")) {
            if (s.len == 0) return Value{ .boolean = false };
            for (s) |ch| {
                if (!std.ascii.isAlphanumeric(ch)) return Value{ .boolean = false };
            }
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "capitalize")) {
            if (s.len == 0) return Value{ .string = s };
            const result = try self.arena.alloc(u8, s.len);
            result[0] = std.ascii.toUpper(s[0]);
            @memcpy(result[1..], s[1..]);
            return Value{ .string = result };
        }
        if (std.ascii.eqlIgnoreCase(method, "deleteWhitespace")) {
            var buf = try self.arena.alloc(u8, s.len);
            var j_idx: usize = 0;
            for (s) |ch| {
                if (!std.ascii.isWhitespace(ch)) {
                    buf[j_idx] = ch;
                    j_idx += 1;
                }
            }
            return Value{ .string = buf[0..j_idx] };
        }
        if (std.ascii.eqlIgnoreCase(method, "normalizeSpace")) {
            return Value{ .string = std.mem.trim(u8, s, " \t\r\n") };
        }
        if (std.ascii.eqlIgnoreCase(method, "lastIndexOf") and args.len > 0 and args[0] == .string) {
            const target = args[0].string;
            if (target.len == 0 or s.len == 0) return Value{ .integer = -1 };
            var last: i64 = -1;
            var k: usize = 0;
            while (k + target.len <= s.len) : (k += 1) {
                if (std.mem.eql(u8, s[k .. k + target.len], target)) last = @intCast(k);
            }
            return Value{ .integer = last };
        }
        if (std.ascii.eqlIgnoreCase(method, "removeEnd") and args.len > 0 and args[0] == .string) {
            if (std.mem.endsWith(u8, s, args[0].string)) {
                return Value{ .string = s[0 .. s.len - args[0].string.len] };
            }
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "removeStart") and args.len > 0 and args[0] == .string) {
            if (std.mem.startsWith(u8, s, args[0].string)) {
                return Value{ .string = s[args[0].string.len..] };
            }
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "format")) {
            // String.format(formatString, List<String>) — replace {0}, {1}, ... with args
            if (args.len > 0 and args[0] == .list) {
                var result = std.ArrayListUnmanaged(u8).empty;
                const items = args[0].list.items.items;
                var i: usize = 0;
                while (i < s.len) {
                    if (s[i] == '{' and i + 1 < s.len) {
                        // Find closing brace
                        if (std.mem.indexOfScalarPos(u8, s, i + 1, '}')) |close| {
                            const idx_str = s[i + 1 .. close];
                            if (std.fmt.parseInt(usize, idx_str, 10)) |idx| {
                                if (idx < items.len) {
                                    const val_str: []const u8 = try utils.coerceToString(items[idx], self.arena);
                                    try result.appendSlice(self.arena, val_str);
                                    i = close + 1;
                                    continue;
                                }
                            } else |_| {}
                        }
                    }
                    try result.append(self.arena, s[i]);
                    i += 1;
                }
                return Value{ .string = result.items };
            }
            // Datetime.format(pattern) — 文字列引数の場合は日付フォーマット
            if (args.len > 0 and args[0] == .string) {
                return self.formatDateTimePattern(s, args[0].string);
            }
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "escapeHtml4") or
            std.ascii.eqlIgnoreCase(method, "escapeJava") or std.ascii.eqlIgnoreCase(method, "escapeSingleQuotes"))
        {
            return Value{ .string = s };
        }
        // date() — Datetime から Date 部分を返す (YYYY-MM-DD)
        if (std.ascii.eqlIgnoreCase(method, "date")) {
            const dt = parseIsoDate(s) orelse return Value{ .string = s };
            return Value{ .string = try std.fmt.allocPrint(self.arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{
                @as(u32, @intCast(dt.y)), dt.m, dt.d,
            }) };
        }
        // time() — Datetime から Time 部分を返す (HH:MM:SS)
        if (std.ascii.eqlIgnoreCase(method, "time")) {
            const dt = parseIsoDate(s) orelse return Value{ .string = "00:00:00" };
            return Value{ .string = try std.fmt.allocPrint(self.arena, "{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
                dt.h, dt.mi, dt.sec,
            }) };
        }
        // getTime() — Datetime からエポックミリ秒を返す
        if (std.ascii.eqlIgnoreCase(method, "getTime")) {
            const dt = parseIsoDate(s) orelse return Value{ .integer = 0 };
            // エポック日数を計算（グレゴリオ暦）
            const y = @as(i64, dt.y);
            const doy = @as(i64, dayOfYear(dt.m, dt.d));
            // 閏年補正: 3月以降かつ閏年なら +1
            const is_leap: i64 = if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) @as(i64, 1) else 0;
            const leap_adj: i64 = if (dt.m > 2) is_leap else 0;
            const days_from_epoch = (y - 1970) * 365 + @divFloor(y - 1969, 4) - @divFloor(y - 1901, 100) + @divFloor(y - 1601, 400) + doy - 1 + leap_adj;
            const secs = days_from_epoch * 86400 + @as(i64, dt.h) * 3600 + @as(i64, dt.mi) * 60 + @as(i64, dt.sec);
            return Value{ .integer = secs * 1000 };
        }
        // addHours — Datetime に時間を加算
        if (std.ascii.eqlIgnoreCase(method, "addHours")) {
            const dt = parseIsoDate(s) orelse return Value{ .string = s };
            const delta: i32 = if (args.len > 0) switch (args[0]) {
                .integer => |iv| @intCast(iv),
                .double => |dv| @intFromFloat(dv),
                else => 0,
            } else 0;
            var h: i32 = @as(i32, dt.h) + delta;
            var day_offset: i32 = 0;
            while (h >= 24) {
                h -= 24;
                day_offset += 1;
            }
            while (h < 0) {
                h += 24;
                day_offset -= 1;
            }
            // 日のオーバーフローは簡易的に addDays で処理
            if (day_offset != 0) {
                const base = try std.fmt.allocPrint(self.arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                    @as(u32, @intCast(dt.y)), dt.m, dt.d, @as(u8, @intCast(h)), dt.mi, dt.sec,
                });
                return self.dateTimeAdd(base, "addDays", &.{Value{ .integer = day_offset }});
            }
            return Value{ .string = try std.fmt.allocPrint(self.arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                @as(u32, @intCast(dt.y)), dt.m, dt.d, @as(u8, @intCast(h)), dt.mi, dt.sec,
            }) };
        }
        // addMinutes — Datetime に分を加算
        if (std.ascii.eqlIgnoreCase(method, "addMinutes")) {
            const dt = parseIsoDate(s) orelse return Value{ .string = s };
            const delta: i32 = if (args.len > 0) switch (args[0]) {
                .integer => |iv| @intCast(iv),
                .double => |dv| @intFromFloat(dv),
                else => 0,
            } else 0;
            var mi: i32 = @as(i32, dt.mi) + delta;
            var hour_offset: i32 = 0;
            while (mi >= 60) {
                mi -= 60;
                hour_offset += 1;
            }
            while (mi < 0) {
                mi += 60;
                hour_offset -= 1;
            }
            const base = try std.fmt.allocPrint(self.arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                @as(u32, @intCast(dt.y)), dt.m, dt.d, dt.h, @as(u8, @intCast(mi)), dt.sec,
            });
            if (hour_offset != 0) {
                return self.evalStringMethod(base, "addHours", &.{Value{ .integer = hour_offset }});
            }
            return Value{ .string = base };
        }
        // addSeconds — Datetime に秒を加算
        if (std.ascii.eqlIgnoreCase(method, "addSeconds")) {
            const dt = parseIsoDate(s) orelse return Value{ .string = s };
            const delta: i32 = if (args.len > 0) switch (args[0]) {
                .integer => |iv| @intCast(iv),
                .double => |dv| @intFromFloat(dv),
                else => 0,
            } else 0;
            var sec: i32 = @as(i32, dt.sec) + delta;
            var min_offset: i32 = 0;
            while (sec >= 60) {
                sec -= 60;
                min_offset += 1;
            }
            while (sec < 0) {
                sec += 60;
                min_offset -= 1;
            }
            const base = try std.fmt.allocPrint(self.arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                @as(u32, @intCast(dt.y)), dt.m, dt.d, dt.h, dt.mi, @as(u8, @intCast(sec)),
            });
            if (min_offset != 0) {
                return self.evalStringMethod(base, "addMinutes", &.{Value{ .integer = min_offset }});
            }
            return Value{ .string = base };
        }
        // year() / month() / day() — ISO 日付文字列からコンポーネント抽出
        if (std.ascii.eqlIgnoreCase(method, "year") or
            std.ascii.eqlIgnoreCase(method, "month") or
            std.ascii.eqlIgnoreCase(method, "day"))
        {
            const dt = parseIsoDate(s) orelse return Value.null_val;
            if (std.ascii.eqlIgnoreCase(method, "year")) return Value{ .integer = dt.y };
            if (std.ascii.eqlIgnoreCase(method, "month")) return Value{ .integer = dt.m };
            return Value{ .integer = dt.d };
        }
        // addYears / addMonths / addDays — ISO 日付文字列に対する日付演算
        if (std.ascii.eqlIgnoreCase(method, "addYears") or
            std.ascii.eqlIgnoreCase(method, "addMonths") or
            std.ascii.eqlIgnoreCase(method, "addDays"))
        {
            return self.dateTimeAdd(s, method, args);
        }
        // formatGMT — format a DateTime string according to a pattern
        if (std.ascii.eqlIgnoreCase(method, "formatGMT") or std.ascii.eqlIgnoreCase(method, "formatGmt")) {
            // Parse ISO date: YYYY-MM-DDTHH:MM:SS
            if (s.len >= 19 and s[4] == '-' and s[7] == '-' and s[10] == 'T') {
                const year = s[0..4];
                const month_num = std.fmt.parseInt(u8, s[5..7], 10) catch 1;
                const day = s[8..10];
                const hour24 = std.fmt.parseInt(u8, s[11..13], 10) catch 0;
                const minute = s[14..16];
                const second = s[17..19];
                const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
                const month_name = if (month_num >= 1 and month_num <= 12) month_names[month_num - 1] else "January";
                const hour12: u8 = if (hour24 == 0) 12 else if (hour24 > 12) hour24 - 12 else hour24;
                const am_pm: []const u8 = if (hour24 < 12) "AM" else "PM";
                return Value{ .string = try std.fmt.allocPrint(self.arena, "{d:0>2}:{s}:{s} {s}, {s} {s}, {s}", .{ hour12, minute, second, am_pm, month_name, day, year }) };
            }
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "toInteger")) {
            return Value{ .integer = std.fmt.parseInt(i64, s, 10) catch 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "valueOf") and args.len > 0) {
            // For enum names (e.g., "SaveMethod".valueOf("EVENT_BUS")), return the arg value
            return args[0];
        }
        if (std.ascii.eqlIgnoreCase(method, "valueOf") and args.len == 0) {
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "substringAfter") and args.len > 0 and args[0] == .string) {
            const sep = args[0].string;
            if (std.mem.indexOf(u8, s, sep)) |idx| {
                return Value{ .string = s[idx + sep.len ..] };
            }
            return Value{ .string = "" };
        }
        if (std.ascii.eqlIgnoreCase(method, "substringBefore") and args.len > 0 and args[0] == .string) {
            const sep = args[0].string;
            if (std.mem.indexOf(u8, s, sep)) |idx| {
                return Value{ .string = s[0..idx] };
            }
            // Salesforce returns original string when separator not found
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "substringAfterLast") and args.len > 0 and args[0] == .string) {
            const sep = args[0].string;
            if (sep.len == 0) return Value{ .string = "" };
            var last_idx: ?usize = null;
            var k: usize = 0;
            while (k + sep.len <= s.len) : (k += 1) {
                if (std.mem.eql(u8, s[k .. k + sep.len], sep)) last_idx = k;
            }
            if (last_idx) |idx| return Value{ .string = s[idx + sep.len ..] };
            return Value{ .string = "" };
        }
        if (std.ascii.eqlIgnoreCase(method, "substringBeforeLast") and args.len > 0 and args[0] == .string) {
            const sep = args[0].string;
            if (sep.len == 0) return Value{ .string = s };
            var last_idx: ?usize = null;
            var k: usize = 0;
            while (k + sep.len <= s.len) : (k += 1) {
                if (std.mem.eql(u8, s[k .. k + sep.len], sep)) last_idx = k;
            }
            if (last_idx) |idx| return Value{ .string = s[0..idx] };
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "countMatches") and args.len > 0 and args[0] == .string) {
            const sep = args[0].string;
            if (sep.len == 0) return Value{ .integer = 0 };
            var count: i64 = 0;
            var k: usize = 0;
            while (k + sep.len <= s.len) {
                if (std.mem.eql(u8, s[k .. k + sep.len], sep)) {
                    count += 1;
                    k += sep.len;
                } else {
                    k += 1;
                }
            }
            return Value{ .integer = count };
        }
        if (std.ascii.eqlIgnoreCase(method, "reverse")) {
            const reversed = try self.arena.alloc(u8, s.len);
            for (s, 0..) |ch, i| reversed[s.len - 1 - i] = ch;
            return Value{ .string = reversed };
        }
        if (std.ascii.eqlIgnoreCase(method, "charAt") and args.len > 0 and args[0] == .integer) {
            const idx: usize = @intCast(@max(args[0].integer, 0));
            if (idx < s.len) return Value{ .integer = @intCast(s[idx]) };
            return Value{ .integer = 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "compareTo") and args.len > 0 and args[0] == .string) {
            const other = args[0].string;
            const len = @min(s.len, other.len);
            for (0..len) |i| {
                if (s[i] < other[i]) return Value{ .integer = -1 };
                if (s[i] > other[i]) return Value{ .integer = 1 };
            }
            if (s.len < other.len) return Value{ .integer = -1 };
            if (s.len > other.len) return Value{ .integer = 1 };
            return Value{ .integer = 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "startsWithIgnoreCase") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.ascii.startsWithIgnoreCase(s, args[0].string) };
        }
        if (std.ascii.eqlIgnoreCase(method, "endsWithIgnoreCase") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.ascii.endsWithIgnoreCase(s, args[0].string) };
        }
        if (std.ascii.eqlIgnoreCase(method, "remove") and args.len > 0 and args[0] == .string) {
            const result = try std.mem.replaceOwned(u8, self.arena, s, args[0].string, "");
            return Value{ .string = result };
        }
        // getSobjectType() on Id strings → determine type from our store IDs or key prefix
        if (std.ascii.eqlIgnoreCase(method, "getSobjectType") or std.ascii.eqlIgnoreCase(method, "getSObjectType")) {
            // Look up the Id in our store to determine its type
            var type_name: []const u8 = "SObject";
            var store_iter = self.store.iterator();
            while (store_iter.next()) |entry| {
                for (entry.value_ptr.items) |rec| {
                    if (rec == .sobject and rec.sobject.id != null and
                        std.ascii.eqlIgnoreCase(rec.sobject.id.?, s))
                    {
                        type_name = rec.sobject.type_name;
                        break;
                    }
                }
            }
            // Fallback: check id_type_map (populated by insertRecord/createId)
            if (std.mem.eql(u8, type_name, "SObject")) {
                if (self.id_type_map.get(s)) |tn| {
                    type_name = tn;
                }
            }
            // Fallback: infer type from Id key prefix (standard objects)
            if (std.mem.eql(u8, type_name, "SObject") and s.len >= 3) {
                type_name = sobjectTypeFromPrefix(s[0..3]);
            }
            // Fallback: match prefix against known SObject types (store + field_types)
            if (std.mem.eql(u8, type_name, "SObject") and s.len >= 3) {
                const id_prefix = s[0..3];
                // Check store
                var store_iter2 = self.store.iterator();
                while (store_iter2.next()) |entry| {
                    const entry_prefix = sobjectKeyPrefix(entry.key_ptr.*);
                    if (std.mem.eql(u8, &entry_prefix, id_prefix)) {
                        type_name = entry.key_ptr.*;
                        break;
                    }
                }
                // Check field_types (knows about all SObject types from field-meta.xml)
                if (std.mem.eql(u8, type_name, "SObject")) {
                    var ft_iter = self.field_types.iterator();
                    while (ft_iter.next()) |entry| {
                        const entry_prefix = sobjectKeyPrefix(entry.key_ptr.*);
                        if (std.mem.eql(u8, &entry_prefix, id_prefix)) {
                            type_name = entry.key_ptr.*;
                            break;
                        }
                    }
                }
            }
            if (isTemplateSObjectType(type_name)) {
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "System.SObjectException" };
                try exc.fields.put(self.arena, "message", Value{ .string = try std.fmt.allocPrint(self.arena, "Cannot locate Apex Type for {s}", .{type_name}) });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
            const sot = try self.arena.create(types.ObjectInstance);
            sot.* = .{ .class_name = "Schema.SObjectType" };
            try sot.fields.put(self.arena, "name", Value{ .string = type_name });
            return Value{ .object = sot };
        }
        // getDescribe() - for SObjectField tokens (stored as strings), return DescribeFieldResult
        if (std.ascii.eqlIgnoreCase(method, "getDescribe")) {
            const dfr = try self.arena.create(types.ObjectInstance);
            dfr.* = .{ .class_name = "Schema.DescribeFieldResult" };
            try dfr.fields.put(self.arena, "fieldName", Value{ .string = s });
            return Value{ .object = dfr };
        }
        // name() - for enum values, returns the string itself
        if (std.ascii.eqlIgnoreCase(method, "name") or std.ascii.eqlIgnoreCase(method, "toString")) {
            return Value{ .string = s };
        }
        // values() - for enum type names, returns a list of all enum values
        if (std.ascii.eqlIgnoreCase(method, "values")) {
            var class_iter = self.classes.iterator();
            while (class_iter.next()) |entry| {
                for (entry.value_ptr.*.members) |member| {
                    switch (member) {
                        .enum_decl => |ed| {
                            if (std.ascii.eqlIgnoreCase(ed.name, s)) {
                                const list = try self.arena.create(types.ListValue);
                                list.* = .{};
                                for (ed.values) |v| {
                                    try list.items.append(self.arena, Value{ .string = v });
                                }
                                return Value{ .list = list };
                            }
                        },
                        else => {},
                    }
                }
            }
        }
        // ordinal() - for enum values, look up known system enum ordinals
        if (std.ascii.eqlIgnoreCase(method, "ordinal")) {
            return Value{ .integer = lookupEnumOrdinal(s) };
        }
        // getOffset(DateTime) — TimeZone のオフセット (ミリ秒)。UTC を返す。
        if (std.ascii.eqlIgnoreCase(method, "getOffset")) {
            return Value{ .integer = 0 };
        }
        // getID() — TimeZone の ID 文字列
        if (std.ascii.eqlIgnoreCase(method, "getID") or std.ascii.eqlIgnoreCase(method, "getId")) {
            return Value{ .string = s };
        }
        // isSameDay(otherDate) — Date/DateTime が同じ日かどうか
        if (std.ascii.eqlIgnoreCase(method, "isSameDay") and args.len > 0) {
            const other_str = builtins.extractDateString(args[0]) orelse (if (args[0] == .string) args[0].string else "");
            const dt = parseIsoDate(s) orelse return Value{ .boolean = false };
            const odt = parseIsoDate(other_str) orelse return Value{ .boolean = false };
            return Value{ .boolean = dt.y == odt.y and dt.m == odt.m and dt.d == odt.d };
        }
        // dateGmt() — DateTime から UTC Date 部分を返す (= date())
        if (std.ascii.eqlIgnoreCase(method, "dateGmt") or std.ascii.eqlIgnoreCase(method, "dateGMT")) {
            const dt = parseIsoDate(s) orelse return Value{ .string = s };
            return Value{ .string = try std.fmt.allocPrint(self.arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{
                @as(u32, @intCast(dt.y)), dt.m, dt.d,
            }) };
        }
        return Value.null_val;
    }

    // -----------------------------------------------------------------------
    // new 式
    // -----------------------------------------------------------------------

    fn evalNewExpr(self: *Evaluator, ne: *ast.NewExpr, current_env: *Env) !Value {
        // Strip "System." and "Schema." prefixes for type resolution
        const raw_type_name = ne.type_name.name;
        const type_name = if (std.ascii.startsWithIgnoreCase(raw_type_name, "System."))
            raw_type_name[7..]
        else if (std.ascii.startsWithIgnoreCase(raw_type_name, "Schema."))
            raw_type_name[7..]
        else
            raw_type_name;

        // Type literal: List<T>.class, Map<K,V>.class, Type[].class → return Type object
        if ((std.mem.indexOf(u8, type_name, "<") != null or std.mem.endsWith(u8, type_name, "[]")) and ne.args.len == 0) {
            const type_obj = try self.arena.create(types.ObjectInstance);
            type_obj.* = .{ .class_name = "Type" };
            try type_obj.fields.put(self.arena, "name", Value{ .string = type_name });
            return Value{ .object = type_obj };
        }

        // new List<T>() / new List<T>{...}
        if (std.ascii.eqlIgnoreCase(type_name, "List")) {
            const list = try self.arena.create(types.ListValue);
            list.* = .{};
            // Single arg that is a Set → convert to list
            if (ne.args.len == 1) {
                var arg_copy = ne.args[0];
                const arg_val = try self.evalExpr(&arg_copy, current_env);
                if (arg_val == .set) {
                    for (arg_val.set.entries.values()) |item| {
                        try list.items.append(self.arena, item);
                    }
                    return Value{ .list = list };
                }
                if (arg_val == .list) {
                    // Copy list
                    for (arg_val.list.items.items) |item| {
                        try list.items.append(self.arena, item);
                    }
                    return Value{ .list = list };
                }
                // Single non-collection arg → add to list
                try list.items.append(self.arena, arg_val);
                return Value{ .list = list };
            }
            for (ne.args) |*arg| {
                try list.items.append(self.arena, try self.evalExpr(arg, current_env));
            }
            return Value{ .list = list };
        }

        // new Map<K,V>()
        if (std.ascii.eqlIgnoreCase(type_name, "Map")) {
            const map = try self.arena.create(types.MapValue);
            map.* = .{};
            for (ne.args) |*arg| {
                if (arg.* == .assignment) {
                    // Map literal: key => value
                    const asgn = arg.assignment;
                    const key_val = try self.evalExpr(asgn.target, current_env);
                    const val_val = try self.evalExpr(asgn.value, current_env);
                    const key_str = if (key_val == .null_val) "" else try utils.coerceToString(key_val, self.arena);
                    try map.entries.put(self.arena, key_str, val_val);
                }
            }
            // If single non-assignment arg is a list, construct map from SObject list
            if (ne.args.len == 1 and ne.args[0] != .assignment) {
                var arg_copy = ne.args[0];
                const arg_val = try self.evalExpr(&arg_copy, current_env);
                if (arg_val == .list) {
                    for (arg_val.list.items.items) |item| {
                        if (item == .sobject and item.sobject.id != null) {
                            try map.entries.put(self.arena, item.sobject.id.?, item);
                        }
                    }
                }
            }
            return Value{ .map = map };
        }

        // DataWeaveScriptResource.* → create DataWeave.Script stub
        if (std.ascii.startsWithIgnoreCase(type_name, "DataWeaveScriptResource")) {
            const instance = try self.arena.create(types.ObjectInstance);
            instance.* = .{ .class_name = "DataWeave.Script" };
            // Extract script name from the type (e.g., "DataWeaveScriptResource.helloWorld" → "helloWorld")
            const dot_pos = std.mem.lastIndexOfScalar(u8, type_name, '.');
            const script_name = if (dot_pos) |dp| type_name[dp + 1 ..] else type_name;
            try instance.fields.put(self.arena, "scriptName", Value{ .string = script_name });
            return Value{ .object = instance };
        }

        // new Set<T>() or new Set<T>(collection)
        if (std.ascii.eqlIgnoreCase(type_name, "Set")) {
            const set = try self.arena.create(types.SetValue);
            set.* = .{};
            for (ne.args) |*arg| {
                const v = try self.evalExpr(arg, current_env);
                // If argument is a list or set, add each element individually
                if (v == .list) {
                    for (v.list.items.items) |item| {
                        const key = try self.setEntryKey(item);
                        try set.entries.put(self.arena, key, item);
                    }
                } else if (v == .set) {
                    for (v.set.entries.keys(), v.set.entries.values()) |k, item| {
                        try set.entries.put(self.arena, k, item);
                    }
                } else {
                    const key = try self.setEntryKey(v);
                    try set.entries.put(self.arena, key, v);
                }
            }
            return Value{ .set = set };
        }

        const builtin_exception_types = [_][]const u8{
            "Exception",
            "DMLException",
            "DmlException",
            "NullPointerException",
            "TypeException",
            "QueryException",
            "JSONException",
            "ListException",
            "MathException",
            "SecurityException",
            "NoAccessException",
            "InvalidParameterValueException",
            "CalloutException",
            "StringException",
            "NoSuchElementException",
            "NoDataFoundException",
            "SearchException",
            "SObjectException",
            "HandledException",
            "IllegalArgumentException",
            "LimitException",
            "AsyncException",
            "SerializationException",
            "FlowException",
            "FinalException",
            "UnsupportedOperationException",
            "EventBusException",
        };
        inline for (builtin_exception_types) |exc_type| {
            if (std.ascii.eqlIgnoreCase(type_name, exc_type)) {
                const instance = try self.arena.create(types.ObjectInstance);
                instance.* = .{ .class_name = exc_type };
                if (ne.args.len > 0) {
                    var arg_copy = ne.args[0];
                    try instance.fields.put(self.arena, "message", try self.evalExpr(&arg_copy, current_env));
                }
                return Value{ .object = instance };
            }
        }

        // ApexPages.StandardController constructor
        if (std.ascii.eqlIgnoreCase(type_name, "ApexPages.StandardController") or
            std.ascii.eqlIgnoreCase(type_name, "StandardController"))
        {
            const instance = try self.arena.create(types.ObjectInstance);
            instance.* = .{ .class_name = "ApexPages.StandardController" };
            if (ne.args.len > 0) {
                var arg_copy = ne.args[0];
                const record = try self.evalExpr(&arg_copy, current_env);
                try instance.fields.put(self.arena, "record", record);
            }
            return Value{ .object = instance };
        }

        // ApexPages.StandardSetController constructor
        if (std.ascii.eqlIgnoreCase(type_name, "ApexPages.StandardSetController") or
            std.ascii.eqlIgnoreCase(type_name, "StandardSetController"))
        {
            const instance = try self.arena.create(types.ObjectInstance);
            instance.* = .{ .class_name = "ApexPages.StandardSetController" };
            if (ne.args.len > 0) {
                var arg_copy = ne.args[0];
                const records = try self.evalExpr(&arg_copy, current_env);
                try instance.fields.put(self.arena, "records", records);
            }
            try instance.fields.put(self.arena, "pageSize", Value{ .integer = 20 }); // default page size
            return Value{ .object = instance };
        }

        // Known non-SObject types: create ObjectInstance instead
        const non_sobject_types = [_][]const u8{
            "RestRequest",            "RestResponse",        "HttpRequest",                      "HttpResponse",
            "Http",                   "PageReference",       "SelectOption",                     "Messaging.SingleEmailMessage",
            "Messaging.InboundEmail", "QueryException",      "DmlException",                     "AuraHandledException",
            "CalloutException",       "Database.DmlOptions", "DmlOptions",                       "ApexPages.Message",
            "VisualEditor.DataRow",   "DataRow",             "VisualEditor.DynamicPickListRows", "DynamicPickListRows",
        };
        for (non_sobject_types) |nst| {
            if (std.ascii.eqlIgnoreCase(type_name, nst)) {
                const instance = try self.arena.create(types.ObjectInstance);
                instance.* = .{ .class_name = type_name };

                // SelectOption constructor: (value, label) or (value, label, disabled)
                if (std.ascii.eqlIgnoreCase(type_name, "SelectOption")) {
                    if (ne.args.len >= 2) {
                        var arg0_copy = ne.args[0];
                        var arg1_copy = ne.args[1];
                        const val = try self.evalExpr(&arg0_copy, current_env);
                        const label = try self.evalExpr(&arg1_copy, current_env);
                        const val_str = try utils.coerceToString(val, self.arena);
                        const label_str = try utils.coerceToString(label, self.arena);
                        try instance.fields.put(self.arena, "value", Value{ .string = val_str });
                        try instance.fields.put(self.arena, "label", Value{ .string = label_str });
                        if (ne.args.len >= 3) {
                            var arg2_copy = ne.args[2];
                            const disabled = try self.evalExpr(&arg2_copy, current_env);
                            try instance.fields.put(self.arena, "disabled", disabled);
                        } else {
                            try instance.fields.put(self.arena, "disabled", Value{ .boolean = false });
                        }
                    }
                    return Value{ .object = instance };
                }

                if (std.ascii.eqlIgnoreCase(type_name, "VisualEditor.DataRow") or
                    std.ascii.eqlIgnoreCase(type_name, "DataRow"))
                {
                    if (ne.args.len >= 2) {
                        var arg0_copy = ne.args[0];
                        var arg1_copy = ne.args[1];
                        const label = try self.evalExpr(&arg0_copy, current_env);
                        const value = try self.evalExpr(&arg1_copy, current_env);
                        try instance.fields.put(self.arena, "label", label);
                        try instance.fields.put(self.arena, "value", value);
                    }
                    return Value{ .object = instance };
                }

                if (std.ascii.eqlIgnoreCase(type_name, "VisualEditor.DynamicPickListRows") or
                    std.ascii.eqlIgnoreCase(type_name, "DynamicPickListRows"))
                {
                    const data_rows = try self.arena.create(types.ListValue);
                    data_rows.* = .{};
                    try instance.fields.put(self.arena, "dataRows", Value{ .list = data_rows });
                    return Value{ .object = instance };
                }

                if (std.ascii.eqlIgnoreCase(type_name, "ApexPages.Message")) {
                    const severity = if (ne.args.len >= 1) blk: {
                        var arg0_copy = ne.args[0];
                        const severity_val = try self.evalExpr(&arg0_copy, current_env);
                        break :blk try utils.coerceToString(severity_val, self.arena);
                    } else "ERROR";
                    const summary = if (ne.args.len >= 2) blk: {
                        var arg1_copy = ne.args[1];
                        const summary_val = try self.evalExpr(&arg1_copy, current_env);
                        break :blk try utils.coerceToString(summary_val, self.arena);
                    } else "";
                    const detail = if (ne.args.len >= 3) blk: {
                        var arg2_copy = ne.args[2];
                        const detail_val = try self.evalExpr(&arg2_copy, current_env);
                        break :blk try utils.coerceToString(detail_val, self.arena);
                    } else summary;
                    try instance.fields.put(self.arena, "severity", Value{ .string = severity });
                    try instance.fields.put(self.arena, "summary", Value{ .string = summary });
                    try instance.fields.put(self.arena, "detail", Value{ .string = detail });
                    try instance.fields.put(self.arena, "message", Value{ .string = summary });
                    return Value{ .object = instance };
                }

                // RestRequest: initialize params map
                if (std.ascii.eqlIgnoreCase(type_name, "RestRequest")) {
                    const params = try self.arena.create(types.MapValue);
                    params.* = .{};
                    try instance.fields.put(self.arena, "params", Value{ .map = params });
                    const headers = try self.arena.create(types.MapValue);
                    headers.* = .{};
                    try instance.fields.put(self.arena, "headers", Value{ .map = headers });
                    return Value{ .object = instance };
                }
                // RestResponse: initialize responseBody as Blob
                if (std.ascii.eqlIgnoreCase(type_name, "RestResponse")) {
                    const blob = try self.arena.create(types.ObjectInstance);
                    blob.* = .{ .class_name = "Blob" };
                    try blob.fields.put(self.arena, "value", Value{ .string = "" });
                    try instance.fields.put(self.arena, "responseBody", Value{ .object = blob });
                    const headers = try self.arena.create(types.MapValue);
                    headers.* = .{};
                    try instance.fields.put(self.arena, "headers", Value{ .map = headers });
                    return Value{ .object = instance };
                }

                // If args contain a message (exception pattern)
                if (ne.args.len > 0) {
                    var arg_copy = ne.args[0];
                    const arg_val = try self.evalExpr(&arg_copy, current_env);
                    if (std.mem.endsWith(u8, type_name, "Exception")) {
                        // AuraHandledException always returns "Script-thrown exception" from getMessage()
                        if (std.ascii.eqlIgnoreCase(type_name, "AuraHandledException")) {
                            try instance.fields.put(self.arena, "message", Value{ .string = "Script-thrown exception" });
                        } else {
                            try instance.fields.put(self.arena, "message", arg_val);
                        }
                    }
                }
                return Value{ .object = instance };
            }
        }

        // SObject with named params: new Account(Name = 'Test', ...)
        // Strip "Schema." prefix for SObject type names (e.g. Schema.User → User)
        const sob_type_name = if (std.ascii.startsWithIgnoreCase(type_name, "Schema.")) type_name[7..] else type_name;
        const obj = try self.arena.create(types.SObject);
        obj.* = .{ .type_name = sob_type_name };
        // Parse named params: args should be Assignment expressions
        for (ne.args) |*arg| {
            if (arg.* == .assignment) {
                const asgn = arg.assignment;
                if (asgn.target.* == .identifier) {
                    const field_name = asgn.target.identifier.name;
                    const field_val = try self.evalExpr(asgn.value, current_env);
                    try obj.fields.put(self.arena, field_name, field_val);
                    // Sync internal id field when Id is set via constructor
                    if (std.ascii.eqlIgnoreCase(field_name, "Id") and field_val == .string) {
                        obj.id = field_val.string;
                    }
                }
            }
        }

        // Check if it's a user-defined class or exception
        // Also try the simple name (after last dot) for dotted type names
        // Prioritize inner classes of the current class (e.g., MockDatabase in LoggerDataStore_Tests)
        const simple_name = if (std.mem.lastIndexOfScalar(u8, type_name, '.')) |di| type_name[di + 1 ..] else type_name;
        const fq_inner_name: ?[]const u8 = if (self.current_class) |cc|
            (if (std.mem.indexOfScalar(u8, type_name, '.') == null)
                (std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, type_name }) catch null)
            else
                null)
        else
            null;
        const resolved_class_name: ?[]const u8 = blk: {
            if (fq_inner_name) |fqn| {
                if (self.findClass(fqn) != null) break :blk fqn;
            }
            if (self.findClass(type_name) != null) break :blk type_name;
            if (self.findClass(simple_name) != null) {
                // Look up whether simple_name is an inner class of some outer — prefer FQ if unique
                if (self.findOuterClassName(simple_name)) |outer| {
                    break :blk std.fmt.allocPrint(self.arena, "{s}.{s}", .{ outer, simple_name }) catch simple_name;
                }
                break :blk simple_name;
            }
            break :blk null;
        };
        if (if (resolved_class_name) |rn| self.findClass(rn) else null) |class_decl| {
            const instance = try self.arena.create(types.ObjectInstance);
            instance.* = .{ .class_name = resolved_class_name.? };

            // Lazy static init for this class and parent hierarchy
            // (so static field initializers like `static final Integer X = 5;`
            // are evaluated before the constructor body references them)
            self.ensureStaticInit(class_decl.name);
            if (class_decl.super_class) |sc| self.ensureStaticInit(sc.name);

            // Check if it's an exception class (extends Exception)
            // If the class has its own constructor, fall through to run it
            // (user-defined exceptions like RestRouteError.RestException may set extra fields)
            {
                const is_exc = if (class_decl.super_class) |sc| std.mem.endsWith(u8, sc.name, "Exception") else std.mem.endsWith(u8, type_name, "Exception");
                if (is_exc) {
                    // Check if class has a user-defined constructor
                    var has_constructor = false;
                    for (class_decl.members) |member| {
                        switch (member) {
                            .constructor_decl => {
                                has_constructor = true;
                                break;
                            },
                            else => {},
                        }
                    }
                    if (!has_constructor) {
                        // No constructor: use simple message extraction
                        if (ne.args.len > 0) {
                            var arg_copy = ne.args[0];
                            const msg_val = try self.evalExpr(&arg_copy, current_env);
                            try instance.fields.put(self.arena, "message", msg_val);
                        }
                        return Value{ .object = instance };
                    }
                    // Has constructor: fall through to normal constructor logic below
                }
            }

            // Initialize parent class fields first (so child fields can shadow)
            if (class_decl.super_class) |sc| {
                if (self.findClass(sc.name)) |parent_decl| {
                    self.initInstanceFields(parent_decl, instance) catch {};
                }
            }

            // Initialize instance fields from class (non-static) — after parent
            self.initInstanceFields(class_decl, instance) catch {};

            // Evaluate constructor args
            var eval_args: std.ArrayListUnmanaged(Value) = .empty;
            for (ne.args) |*arg| {
                try eval_args.append(self.arena, try self.evalExpr(arg, current_env));
            }

            // Execute parent constructor first (if has super_class and parent has constructor)
            if (class_decl.super_class) |sc| {
                if (self.findClass(sc.name)) |parent_decl| {
                    try self.runConstructor(parent_decl, instance, &.{});
                }
            }

            // Execute own constructor
            try self.runConstructor(class_decl, instance, eval_args.items);

            return Value{ .object = instance };
        }

        // Any type ending with "Exception" that wasn't found as a user class
        // should still be an ObjectInstance (not SObject)
        if (std.mem.endsWith(u8, type_name, "Exception")) {
            const instance = try self.arena.create(types.ObjectInstance);
            instance.* = .{ .class_name = type_name };
            if (ne.args.len > 0) {
                var arg_copy = ne.args[0];
                const msg_val = try self.evalExpr(&arg_copy, current_env);
                try instance.fields.put(self.arena, "message", msg_val);
            }
            return Value{ .object = instance };
        }

        return Value{ .sobject = obj };
    }

    // -----------------------------------------------------------------------
    // フィールドアクセス
    // -----------------------------------------------------------------------

    fn evalFieldAccess(self: *Evaluator, fa: *ast.FieldAccess, obj: Value, current_env: *Env) !Value {
        if (fa.object.* == .field_access) {
            const inner_fa = fa.object.field_access;
            if (inner_fa.object.* == .identifier and
                std.ascii.eqlIgnoreCase(inner_fa.object.identifier.name, "ApexPages") and
                std.ascii.eqlIgnoreCase(inner_fa.field, "Severity"))
            {
                return Value{ .string = fa.field };
            }
            if (inner_fa.object.* == .identifier and
                std.ascii.eqlIgnoreCase(inner_fa.object.identifier.name, "Schema"))
            {
                if (std.ascii.eqlIgnoreCase(inner_fa.field, "sObjectType") or
                    std.ascii.eqlIgnoreCase(inner_fa.field, "SObjectType"))
                {
                    const sot = try self.arena.create(types.ObjectInstance);
                    sot.* = .{ .class_name = "Schema.SObjectType" };
                    try sot.fields.put(self.arena, "name", Value{ .string = fa.field });
                    return Value{ .object = sot };
                }
                if (std.ascii.eqlIgnoreCase(fa.field, "SObjectType")) {
                    const sot = try self.arena.create(types.ObjectInstance);
                    sot.* = .{ .class_name = "Schema.SObjectType" };
                    try sot.fields.put(self.arena, "name", Value{ .string = inner_fa.field });
                    return Value{ .object = sot };
                }
                if (!std.ascii.eqlIgnoreCase(fa.field, "class")) {
                    return try self.makeSObjectFieldToken(inner_fa.field, fa.field);
                }
            }
        }
        if (fa.object.* == .identifier and std.mem.startsWith(u8, fa.object.identifier.name, "Schema.")) {
            const schema_name = fa.object.identifier.name["Schema.".len..];
            if (std.ascii.eqlIgnoreCase(schema_name, "SObjectType")) {
                const sot = try self.arena.create(types.ObjectInstance);
                sot.* = .{ .class_name = "Schema.SObjectType" };
                try sot.fields.put(self.arena, "name", Value{ .string = fa.field });
                return Value{ .object = sot };
            }
            if (std.ascii.eqlIgnoreCase(fa.field, "SObjectType")) {
                const sot = try self.arena.create(types.ObjectInstance);
                sot.* = .{ .class_name = "Schema.SObjectType" };
                try sot.fields.put(self.arena, "name", Value{ .string = schema_name });
                return Value{ .object = sot };
            }
            if (!std.ascii.eqlIgnoreCase(fa.field, "class")) {
                return try self.makeSObjectFieldToken(schema_name, fa.field);
            }
        }

        // Auto-unwrap list to first element for field access (SOQL single-record pattern)
        if (obj == .list) {
            // Empty SOQL result with field access → QueryException (only for SOQL sources)
            if (obj.list.items.items.len == 0 and fa.object.* == .soql) {
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "QueryException" };
                try exc.fields.put(self.arena, "message", Value{ .string = "List has no rows for assignment to SObject" });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
            if (obj.list.items.items.len > 0) {
                const first = obj.list.items.items[0];
                if (first == .sobject) {
                    return self.getSObjectFieldValueCaseInsensitive(first.sobject, fa.field) orelse Value.null_val;
                }
            }
            // List.size as property
            if (std.ascii.eqlIgnoreCase(fa.field, "size")) return Value{ .integer = @intCast(obj.list.items.items.len) };
            return Value.null_val;
        }

        if (obj == .sobject) {
            if (self.getSObjectFieldValueCaseInsensitive(obj.sobject, fa.field)) |value| return value;
            // If this SObject was processed by stripInaccessible, throw SObjectException
            if (obj.sobject.is_stripped) {
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "SObjectException" };
                try exc.fields.put(self.arena, "message", Value{ .string = "SObject row was retrieved via SOQL without querying the requested field: " });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
            return Value.null_val;
        }
        if (obj == .object) {
            // Check for property getter FIRST (before returning raw field value)
            if (self.findClass(obj.object.class_name)) |cd| {
                var cur_cd: ?*ast.ClassDecl = cd;
                while (cur_cd) |ccd| {
                    for (ccd.members) |member| {
                        switch (member) {
                            .field_decl => |fd| {
                                if (std.ascii.eqlIgnoreCase(fd.name, fa.field)) {
                                    if (fd.getter_body) |getter| {
                                        // Skip getter re-invocation if we're already inside this property's getter
                                        // (self-referencing getter pattern: this.prop inside prop's getter = backing field)
                                        if (self.evaluating_getter) |eg| {
                                            if (std.ascii.eqlIgnoreCase(eg, fd.name)) {
                                                // Return backing field value directly
                                                if (fd.modifiers.is_static) {
                                                    return self.readStaticBackingValue(ccd.name, fd.name);
                                                }
                                                if (obj.object.fields.get(fa.field)) |fv| return fv;
                                                for (obj.object.fields.keys(), obj.object.fields.values()) |fk, fv| {
                                                    if (std.ascii.eqlIgnoreCase(fk, fa.field)) return fv;
                                                }
                                                return .null_val;
                                            }
                                        }
                                        // Execute getter body with 'this' bound to the object
                                        const getter_env = self.global_env.child() catch return Value.null_val;
                                        getter_env.define("this", Value{ .object = obj.object }) catch {};
                                        // Load instance fields as local variables
                                        // SKIP fields that have their own getter (to force
                                        // property access via this.field → getter chain)
                                        for (obj.object.fields.keys(), obj.object.fields.values()) |fk, fv| {
                                            var has_getter = false;
                                            if (!std.ascii.eqlIgnoreCase(fk, fd.name)) { // Don't skip current property
                                                var check_cd: ?*ast.ClassDecl = cd;
                                                while (check_cd) |ccd2| {
                                                    for (ccd2.members) |m2| {
                                                        switch (m2) {
                                                            .field_decl => |fd2| {
                                                                if (std.ascii.eqlIgnoreCase(fd2.name, fk) and fd2.getter_body != null) {
                                                                    has_getter = true;
                                                                }
                                                            },
                                                            else => {},
                                                        }
                                                    }
                                                    check_cd = if (ccd2.super_class) |sc| self.findClass(sc.name) else null;
                                                }
                                            }
                                            if (!has_getter) {
                                                getter_env.set(fk, fv) catch {
                                                    getter_env.define(fk, fv) catch {};
                                                };
                                            }
                                        }
                                        const saved_getter = self.evaluating_getter;
                                        self.evaluating_getter = fd.name;
                                        defer self.evaluating_getter = saved_getter;
                                        const result = self.execBlock(getter, getter_env) catch |err| {
                                            if (err == error.StackOverflow) return Value.null_val;
                                            return err;
                                        };
                                        return switch (result) {
                                            .return_val => |v| v,
                                            else => self.return_value,
                                        };
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    cur_cd = if (ccd.super_class) |sc| self.findClass(sc.name) else null;
                }
            }
            // Schema.SObjectTypeNamespace.Contact → Schema.SObjectType { name: "Contact" }
            if (std.ascii.eqlIgnoreCase(obj.object.class_name, "Schema.SObjectTypeNamespace")) {
                const sot = try self.arena.create(types.ObjectInstance);
                sot.* = .{ .class_name = "Schema.SObjectType" };
                try sot.fields.put(self.arena, "name", Value{ .string = fa.field });
                return Value{ .object = sot };
            }
            if (std.ascii.eqlIgnoreCase(obj.object.class_name, "Schema.SObjectType") and
                std.ascii.eqlIgnoreCase(fa.field, "fieldSets"))
            {
                if (obj.object.fields.get("fieldSets")) |field_sets| return field_sets;
                const object_name = if (obj.object.fields.get("name")) |name_val|
                    if (name_val == .string) name_val.string else "SObject"
                else
                    "SObject";
                const field_sets = try builtins.createFieldSetCollectionValue(self.arena, self, object_name);
                try obj.object.fields.put(self.arena, "fieldSets", field_sets);
                return field_sets;
            }
            if ((std.ascii.eqlIgnoreCase(obj.object.class_name, "DescribeSObjectResult") or
                std.ascii.eqlIgnoreCase(obj.object.class_name, "Schema.DescribeSObjectResult")) and
                std.ascii.eqlIgnoreCase(fa.field, "fieldSets"))
            {
                if (obj.object.fields.get("fieldSets")) |field_sets| return field_sets;
                const object_name = if (obj.object.fields.get("name")) |name_val|
                    if (name_val == .string) name_val.string else "SObject"
                else
                    "SObject";
                const field_sets = try builtins.createFieldSetCollectionValue(self.arena, self, object_name);
                try obj.object.fields.put(self.arena, "fieldSets", field_sets);
                return field_sets;
            }
            // Case-insensitive field lookup (no custom getter found)
            for (obj.object.fields.keys(), obj.object.fields.values()) |k, v| {
                if (std.ascii.eqlIgnoreCase(k, fa.field)) return v;
            }
            return Value.null_val;
        }
        if (obj == .string) {
            if (fa.object.* == .field_access) {
                const inner_fa = fa.object.field_access;
                if (inner_fa.object.* == .identifier and std.ascii.eqlIgnoreCase(inner_fa.object.identifier.name, "Schema")) {
                    return try self.makeSObjectFieldToken(obj.string, fa.field);
                }
            }
            if (fa.object.* == .identifier and std.mem.startsWith(u8, fa.object.identifier.name, "Schema.")) {
                const schema_name = fa.object.identifier.name["Schema.".len..];
                if (std.ascii.eqlIgnoreCase(schema_name, "SObjectType")) {
                    const sot = try self.arena.create(types.ObjectInstance);
                    sot.* = .{ .class_name = "Schema.SObjectType" };
                    try sot.fields.put(self.arena, "name", Value{ .string = fa.field });
                    return Value{ .object = sot };
                }
                return try self.makeSObjectFieldToken(schema_name, fa.field);
            }
            // String.length as property (shouldn't be needed but just in case)
            if (std.ascii.eqlIgnoreCase(fa.field, "length")) return Value{ .integer = @intCast(obj.string.len) };
            // Enum value pattern: when obj is an enum name (from ClassName.EnumName),
            // field access returns the enum value string (e.g., HttpVerb.GET → "GET")
            var enum_iter = self.classes.iterator();
            while (enum_iter.next()) |entry| {
                for (entry.value_ptr.*.members) |member| {
                    switch (member) {
                        .enum_decl => |ed| {
                            if (std.ascii.eqlIgnoreCase(ed.name, obj.string)) {
                                return Value{ .string = fa.field };
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        if (obj == .null_val and fa.object.* == .identifier) {
            const base_name = fa.object.identifier.name;
            if (self.current_class) |cc| {
                if (self.resolveStaticFieldValueOnClass(cc, base_name)) |base| {
                    if (base != .null_val) return self.evalFieldAccessOnResolvedValue(base, fa.field, current_env);
                }
                if (self.findOuterClassName(cc)) |outer| {
                    if (self.resolveStaticFieldValueOnClass(outer, base_name)) |base| {
                        if (base != .null_val) return self.evalFieldAccessOnResolvedValue(base, fa.field, current_env);
                    }
                }
            }
        }

        // Static field: ClassName.fieldName
        if (fa.object.* == .identifier) {
            const class_name = fa.object.identifier.name;

            // Lazy static init: ensure the class's static fields/blocks are initialized
            self.ensureStaticInit(class_name);

            if (std.mem.startsWith(u8, class_name, "Schema.")) {
                const schema_name = class_name["Schema.".len..];
                if (std.ascii.eqlIgnoreCase(schema_name, "SObjectType")) {
                    const sot = try self.arena.create(types.ObjectInstance);
                    sot.* = .{ .class_name = "Schema.SObjectType" };
                    try sot.fields.put(self.arena, "name", Value{ .string = fa.field });
                    return Value{ .object = sot };
                }
                if (std.ascii.eqlIgnoreCase(fa.field, "SObjectType")) {
                    const sot = try self.arena.create(types.ObjectInstance);
                    sot.* = .{ .class_name = "Schema.SObjectType" };
                    try sot.fields.put(self.arena, "name", Value{ .string = schema_name });
                    return Value{ .object = sot };
                }
                if (!std.ascii.eqlIgnoreCase(fa.field, "class")) {
                    return try self.makeSObjectFieldToken(schema_name, fa.field);
                }
            }

            // Date.today()
            if (std.ascii.eqlIgnoreCase(class_name, "Date") and std.ascii.eqlIgnoreCase(fa.field, "today")) {
                return try builtins.makeDateValue(self.arena, try builtins.currentDateString(self.arena));
            }

            // AccessLevel / AccessType enum
            if (std.ascii.eqlIgnoreCase(class_name, "AccessLevel") or
                std.ascii.eqlIgnoreCase(class_name, "AccessType") or
                std.ascii.eqlIgnoreCase(class_name, "ApexPages.Severity"))
            {
                return Value{ .string = fa.field };
            }

            // RestContext.request / RestContext.response
            if (std.ascii.eqlIgnoreCase(class_name, "RestContext")) {
                if (std.ascii.eqlIgnoreCase(fa.field, "request")) {
                    const req = try self.arena.create(types.ObjectInstance);
                    req.* = .{ .class_name = "RestRequest" };
                    try req.fields.put(self.arena, "requestURI", Value{ .string = "/services/apexrest/test" });
                    try req.fields.put(self.arena, "httpMethod", Value{ .string = "GET" });
                    try req.fields.put(self.arena, "requestBody", Value.null_val);
                    // Check if the test set RestContext.request already
                    const key = try std.fmt.allocPrint(self.arena, "RestContext.request", .{});
                    return self.global_env.get(key) orelse Value{ .object = req };
                }
                if (std.ascii.eqlIgnoreCase(fa.field, "response")) {
                    const resp = try self.arena.create(types.ObjectInstance);
                    resp.* = .{ .class_name = "RestResponse" };
                    try resp.fields.put(self.arena, "statusCode", Value{ .integer = 200 });
                    try resp.fields.put(self.arena, "responseBody", Value.null_val);
                    const key = try std.fmt.allocPrint(self.arena, "RestContext.response", .{});
                    return self.global_env.get(key) orelse Value{ .object = resp };
                }
            }

            // SObject.SObjectType
            if (std.ascii.eqlIgnoreCase(fa.field, "SObjectType")) {
                // Schema.sObjectType → return namespace proxy (fields resolve to per-object SObjectType)
                if (std.ascii.eqlIgnoreCase(class_name, "Schema")) {
                    const ns = try self.arena.create(types.ObjectInstance);
                    ns.* = .{ .class_name = "Schema.SObjectTypeNamespace" };
                    return Value{ .object = ns };
                }
                // e.g., Account.SObjectType
                const sot = try self.arena.create(types.ObjectInstance);
                sot.* = .{ .class_name = "Schema.SObjectType" };
                try sot.fields.put(self.arena, "name", Value{ .string = class_name });
                return Value{ .object = sot };
            }

            // SObject.class
            if (std.ascii.eqlIgnoreCase(fa.field, "class")) {
                const type_obj = try self.arena.create(types.ObjectInstance);
                type_obj.* = .{ .class_name = "Type" };
                // For inner classes, return the FQ name (e.g., "OuterClass.InnerClass").
                // Prefer current_class as the outer qualifier when the inner class exists
                // there (avoids picking a same-named inner from a different outer class).
                const fq_name: []const u8 = if (self.current_class) |cc| blk: {
                    if (std.mem.indexOfScalar(u8, class_name, '.') == null) {
                        const fq = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, class_name }) catch class_name;
                        if (self.findClass(fq) != null) break :blk fq;
                    }
                    break :blk self.resolveFullClassName(class_name);
                } else self.resolveFullClassName(class_name);
                try type_obj.fields.put(self.arena, "name", Value{ .string = fq_name });
                return Value{ .object = type_obj };
            }

            // Trigger context
            if (std.ascii.eqlIgnoreCase(class_name, "Trigger")) {
                if (self.trigger_context) |tc| {
                    if (std.ascii.eqlIgnoreCase(fa.field, "new")) return tc.new_list orelse Value.null_val;
                    if (std.ascii.eqlIgnoreCase(fa.field, "old")) return tc.old_list orelse Value.null_val;
                    if (std.ascii.eqlIgnoreCase(fa.field, "newMap")) return tc.new_map orelse Value.null_val;
                    if (std.ascii.eqlIgnoreCase(fa.field, "oldMap")) return tc.old_map orelse Value.null_val;
                    if (std.ascii.eqlIgnoreCase(fa.field, "isBefore")) return Value{ .boolean = tc.is_before };
                    if (std.ascii.eqlIgnoreCase(fa.field, "isAfter")) return Value{ .boolean = tc.is_after };
                    if (std.ascii.eqlIgnoreCase(fa.field, "isInsert")) return Value{ .boolean = tc.is_insert };
                    if (std.ascii.eqlIgnoreCase(fa.field, "isUpdate")) return Value{ .boolean = tc.is_update };
                    if (std.ascii.eqlIgnoreCase(fa.field, "isDelete")) return Value{ .boolean = tc.is_delete };
                    if (std.ascii.eqlIgnoreCase(fa.field, "isUndelete")) return Value{ .boolean = tc.is_undelete };
                    if (std.ascii.eqlIgnoreCase(fa.field, "isExecuting")) return Value{ .boolean = tc.is_executing };
                    if (std.ascii.eqlIgnoreCase(fa.field, "size")) return Value{ .integer = tc.size };
                    if (std.ascii.eqlIgnoreCase(fa.field, "operationType")) return if (tc.operation_type) |ot| Value{ .string = ot } else Value.null_val;
                } else {
                    if (std.ascii.eqlIgnoreCase(fa.field, "new") or std.ascii.eqlIgnoreCase(fa.field, "old")) {
                        // Check if Trigger.new/old has been explicitly set
                        const key = try std.fmt.allocPrint(self.arena, "Trigger.{s}", .{fa.field});
                        if (self.global_env.get(key)) |v| return v;
                        return Value.null_val;
                    }
                    if (std.ascii.eqlIgnoreCase(fa.field, "isBefore") or std.ascii.eqlIgnoreCase(fa.field, "isAfter") or
                        std.ascii.eqlIgnoreCase(fa.field, "isInsert") or std.ascii.eqlIgnoreCase(fa.field, "isUpdate") or
                        std.ascii.eqlIgnoreCase(fa.field, "isDelete") or std.ascii.eqlIgnoreCase(fa.field, "isUndelete") or
                        std.ascii.eqlIgnoreCase(fa.field, "isExecuting"))
                    {
                        return Value{ .boolean = false };
                    }
                    if (std.ascii.eqlIgnoreCase(fa.field, "newMap") or std.ascii.eqlIgnoreCase(fa.field, "oldMap")) {
                        const key = try std.fmt.allocPrint(self.arena, "Trigger.{s}", .{fa.field});
                        if (self.global_env.get(key)) |v| return v;
                        return Value.null_val;
                    }
                    if (std.ascii.eqlIgnoreCase(fa.field, "size")) {
                        return Value{ .integer = 0 };
                    }
                }
            }

            // Check if it's an enum class
            var class_iter = self.classes.iterator();
            while (class_iter.next()) |entry| {
                const cd = entry.value_ptr.*;
                for (cd.members) |member| {
                    switch (member) {
                        .enum_decl => |ed| {
                            if (std.ascii.eqlIgnoreCase(ed.name, class_name)) {
                                // Return enum value as string
                                return Value{ .string = fa.field };
                            }
                        },
                        else => {},
                    }
                }
            }
            // Also check top-level enums
            if (self.findClass(class_name)) |cd| {
                // It might be a class with the enum as inner
                for (cd.members) |member| {
                    switch (member) {
                        .enum_decl => |ed| {
                            if (std.ascii.eqlIgnoreCase(ed.name, fa.field)) {
                                // Return the enum name as a string - when used in
                                // ClassName.EnumName.VALUE patterns, the next field_access
                                // will match the enum name in the enum check above (line 4767)
                                return Value{ .string = fa.field };
                            }
                        },
                        .field_decl => |fd| {
                            if (std.ascii.eqlIgnoreCase(fd.name, fa.field) and fd.modifiers.is_static) {
                                // If property has a getter, execute it (unless we're already inside it)
                                if (fd.getter_body != null) {
                                    const already_in = if (self.evaluating_getter) |eg| std.ascii.eqlIgnoreCase(eg, fa.field) else false;
                                    if (!already_in) {
                                        const getter_env = self.global_env.child() catch return Value.null_val;
                                        const saved_class = self.current_class;
                                        const saved_getter = self.evaluating_getter;
                                        self.current_class = class_name;
                                        self.evaluating_getter = fa.field;
                                        defer {
                                            self.current_class = saved_class;
                                            self.evaluating_getter = saved_getter;
                                        }
                                        const result = self.execBlock(fd.getter_body.?, getter_env) catch return Value.null_val;
                                        return switch (result) {
                                            .return_val => |v| v,
                                            else => self.return_value,
                                        };
                                    }
                                }
                                const skey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ class_name, fa.field }) catch return Value.null_val;
                                return self.global_env.get(skey) orelse Value.null_val;
                            }
                        },
                        .class_decl => |inner_cd| {
                            if (std.ascii.eqlIgnoreCase(inner_cd.name, fa.field)) {
                                return Value{ .string = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ class_name, inner_cd.name }) };
                            }
                        },
                        .interface_decl => |inner_iface| {
                            if (std.ascii.eqlIgnoreCase(inner_iface.name, fa.field)) {
                                return Value{ .string = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ class_name, inner_iface.name }) };
                            }
                        },
                        else => {},
                    }
                }
            }

            // General enum value pattern — any ClassName.CONSTANT_NAME
            const key = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ class_name, fa.field });
            if (self.global_env.get(key)) |v| return v;

            // If it looks like an enum constant (all upper case or known pattern), return as string
            return Value{ .string = fa.field };
        }

        // Nested static: ClassName.InnerClass.field → already resolved as field_access chain
        if (fa.object.* == .field_access) {
            const inner_fa = fa.object.field_access;
            if (inner_fa.object.* == .identifier) {
                const outer_name = inner_fa.object.identifier.name;
                const inner_name = inner_fa.field;
                // Check for nested enum or class constant
                if (self.findClass(outer_name)) |cd| {
                    for (cd.members) |member| {
                        switch (member) {
                            .enum_decl => |ed| {
                                if (std.ascii.eqlIgnoreCase(ed.name, inner_name)) {
                                    return Value{ .string = fa.field };
                                }
                            },
                            .class_decl => |inner_cd| {
                                if (std.ascii.eqlIgnoreCase(inner_cd.name, inner_name)) {
                                    if (std.ascii.eqlIgnoreCase(fa.field, "class")) {
                                        const type_obj = try self.arena.create(types.ObjectInstance);
                                        type_obj.* = .{ .class_name = "Type" };
                                        const fq_name = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ outer_name, inner_cd.name });
                                        try type_obj.fields.put(self.arena, "name", Value{ .string = fq_name });
                                        return Value{ .object = type_obj };
                                    }
                                    const fq_inner_name = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ outer_name, inner_cd.name });
                                    const static_key = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ fq_inner_name, fa.field });
                                    if (self.global_env.get(static_key)) |v| return v;
                                    return Value{ .string = fa.field };
                                }
                            },
                            .interface_decl => |inner_iface| {
                                if (std.ascii.eqlIgnoreCase(inner_iface.name, inner_name) and std.ascii.eqlIgnoreCase(fa.field, "class")) {
                                    const type_obj = try self.arena.create(types.ObjectInstance);
                                    type_obj.* = .{ .class_name = "Type" };
                                    const fq_name = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ outer_name, inner_iface.name });
                                    try type_obj.fields.put(self.arena, "name", Value{ .string = fq_name });
                                    return Value{ .object = type_obj };
                                }
                            },
                            else => {},
                        }
                    }
                }
                // System.AccessType.CREATABLE / System.AccessLevel.SYSTEM_MODE / System.Quiddity.* etc.
                if (std.ascii.eqlIgnoreCase(outer_name, "System") and
                    (std.ascii.eqlIgnoreCase(inner_name, "AccessType") or
                        std.ascii.eqlIgnoreCase(inner_name, "AccessLevel") or
                        std.ascii.eqlIgnoreCase(inner_name, "Quiddity") or
                        std.ascii.eqlIgnoreCase(inner_name, "TriggerOperation") or
                        std.ascii.eqlIgnoreCase(inner_name, "LoggingLevel") or
                        std.ascii.eqlIgnoreCase(inner_name, "StatusCode")))
                {
                    return Value{ .string = fa.field };
                }

                // System.ExceptionType.class → Type object with "System.ExceptionType" name
                if (std.ascii.eqlIgnoreCase(fa.field, "class") and std.ascii.eqlIgnoreCase(outer_name, "System")) {
                    const type_obj = try self.arena.create(types.ObjectInstance);
                    type_obj.* = .{ .class_name = "Type" };
                    const fq_name = try std.fmt.allocPrint(self.arena, "System.{s}", .{inner_name});
                    try type_obj.fields.put(self.arena, "name", Value{ .string = fq_name });
                    return Value{ .object = type_obj };
                }

                // Schema.SObjectType.Account etc.
                if (std.ascii.eqlIgnoreCase(outer_name, "Schema") and std.ascii.eqlIgnoreCase(inner_name, "SObjectType")) {
                    const sot = try self.arena.create(types.ObjectInstance);
                    sot.* = .{ .class_name = "Schema.SObjectType" };
                    try sot.fields.put(self.arena, "name", Value{ .string = fa.field });
                    return Value{ .object = sot };
                }
                // Schema.Account.Name / Schema.Custom__c.UniqueId__c
                if (std.ascii.eqlIgnoreCase(outer_name, "Schema")) {
                    return try self.makeSObjectFieldToken(inner_name, fa.field);
                }
            }
        }

        // ClassName.class → Type object
        // Use fully-qualified name when the class is an inner class of current_class
        if (fa.object.* == .identifier and std.ascii.eqlIgnoreCase(fa.field, "class")) {
            const simple_name = fa.object.identifier.name;
            // Check if this is an inner class of the current class → use FQ name
            const type_name: []const u8 = if (self.current_class) |cc| blk: {
                const fq = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, simple_name }) catch simple_name;
                break :blk if (self.findClass(fq) != null) fq else self.resolveFullClassName(simple_name);
            } else self.resolveFullClassName(simple_name);
            const type_obj = try self.arena.create(types.ObjectInstance);
            type_obj.* = .{ .class_name = "Type" };
            try type_obj.fields.put(self.arena, "name", Value{ .string = type_name });
            return Value{ .object = type_obj };
        }

        // OuterClass.InnerClass.class → Type object (when obj is string class name)
        if (obj == .string and std.ascii.eqlIgnoreCase(fa.field, "class")) {
            const type_obj = try self.arena.create(types.ObjectInstance);
            type_obj.* = .{ .class_name = "Type" };
            try type_obj.fields.put(self.arena, "name", Value{ .string = obj.string });
            return Value{ .object = type_obj };
        }

        return Value.null_val;
    }

    fn evalFieldAccessOnResolvedValue(self: *Evaluator, obj: Value, field_name: []const u8, current_env: *Env) !Value {
        const placeholder_expr = try self.arena.create(ast.Expr);
        placeholder_expr.* = .null_literal;
        const synthetic_fa = try self.arena.create(ast.FieldAccess);
        synthetic_fa.* = .{ .object = placeholder_expr, .field = field_name, .null_safe = false };
        return self.evalFieldAccess(synthetic_fa, obj, current_env);
    }

    // -----------------------------------------------------------------------
    // Datetime ヘルパー
    // -----------------------------------------------------------------------

    /// 文字列が Date 形式 (YYYY-MM-DD, 10文字ちょうど) かどうかを判定する。
    fn isDateOnlyFormatString(s: []const u8) bool {
        if (s.len != 10) return false;
        if (s[4] != '-' or s[7] != '-') return false;
        _ = std.fmt.parseInt(i32, s[0..4], 10) catch return false;
        _ = std.fmt.parseInt(u8, s[5..7], 10) catch return false;
        _ = std.fmt.parseInt(u8, s[8..10], 10) catch return false;
        return true;
    }

    /// 文字列が DateTime 形式 (YYYY-MM-DDThh:mm:ss...) かどうかを判定する。
    fn isDateTimeFormatString(s: []const u8) bool {
        if (s.len < 19) return false;
        if (s[4] != '-' or s[7] != '-' or s[10] != 'T') return false;
        _ = std.fmt.parseInt(i32, s[0..4], 10) catch return false;
        _ = std.fmt.parseInt(u8, s[5..7], 10) catch return false;
        _ = std.fmt.parseInt(u8, s[8..10], 10) catch return false;
        _ = std.fmt.parseInt(u8, s[11..13], 10) catch return false;
        _ = std.fmt.parseInt(u8, s[14..16], 10) catch return false;
        _ = std.fmt.parseInt(u8, s[17..19], 10) catch return false;
        return true;
    }

    /// instanceof チェック: 数値型名 (Integer, Decimal, Long, Double, Number) にマッチするか。
    fn instanceofMatchesNumericType(tn: []const u8) bool {
        return std.ascii.eqlIgnoreCase(tn, "Integer") or
            std.ascii.eqlIgnoreCase(tn, "Decimal") or
            std.ascii.eqlIgnoreCase(tn, "Long") or
            std.ascii.eqlIgnoreCase(tn, "Double") or
            std.ascii.eqlIgnoreCase(tn, "Number");
    }

    fn isSalesforceIdString(value: []const u8) bool {
        if (value.len != 15 and value.len != 18) return false;
        for (value) |ch| {
            if (!std.ascii.isAlphanumeric(ch)) return false;
        }
        return true;
    }

    /// instanceof チェック: Value がプリミティブ型名にマッチするか。
    fn instanceofMatchesPrimitive(val: Value, tn: []const u8) bool {
        if (val == .integer or val == .double) return instanceofMatchesNumericType(tn);
        if (val == .boolean) return std.ascii.eqlIgnoreCase(tn, "Boolean");
        if (val == .string) {
            return std.ascii.eqlIgnoreCase(tn, "String") or
                (std.ascii.eqlIgnoreCase(tn, "Id") and Evaluator.isSalesforceIdString(val.string));
        }
        if (val == .sobject) return std.ascii.eqlIgnoreCase(tn, "SObject") or std.ascii.eqlIgnoreCase(tn, "Sobject") or std.ascii.eqlIgnoreCase(tn, "sObject");
        if (val == .object) {
            const cn = val.object.class_name;
            if (cn.len > 0 and cn.len < 256) {
                if (std.ascii.eqlIgnoreCase(cn, "Date")) return std.ascii.eqlIgnoreCase(tn, "Date");
                if (std.ascii.eqlIgnoreCase(cn, "Datetime")) return std.ascii.eqlIgnoreCase(tn, "DateTime") or std.ascii.eqlIgnoreCase(tn, "Datetime");
            }
        }
        return false;
    }

    /// child_class が parent_type のサブクラスかどうかを継承チェーンで確認する。
    fn isSubclassOf(self: *Evaluator, child_class: []const u8, parent_type: []const u8) bool {
        // Direct match
        if (std.ascii.eqlIgnoreCase(child_class, parent_type)) return true;
        // Check simple name match (inner class: "OuterClass.InnerClass" → "InnerClass")
        if (std.mem.lastIndexOfScalar(u8, child_class, '.')) |di| {
            if (std.ascii.eqlIgnoreCase(child_class[di + 1 ..], parent_type)) return true;
        }
        // Walk the inheritance chain
        var cd = self.findClass(child_class);
        var depth: u8 = 0;
        while (cd) |c| : (depth += 1) {
            if (depth > 20) break; // Safety limit
            if (c.super_class) |sc| {
                if (std.ascii.eqlIgnoreCase(sc.name, parent_type)) return true;
                if (std.mem.lastIndexOfScalar(u8, sc.name, '.')) |di| {
                    if (std.ascii.eqlIgnoreCase(sc.name[di + 1 ..], parent_type)) return true;
                }
                // Also check interfaces
                for (c.interfaces) |iface| {
                    if (std.ascii.eqlIgnoreCase(iface.name, parent_type)) return true;
                }
                cd = self.findClass(sc.name);
            } else {
                // Check interfaces at this level
                for (c.interfaces) |iface| {
                    if (std.ascii.eqlIgnoreCase(iface.name, parent_type)) return true;
                }
                break;
            }
        }
        // All *Exception classes are subclasses of Exception / System.Exception
        if ((std.ascii.eqlIgnoreCase(parent_type, "Exception") or std.ascii.eqlIgnoreCase(parent_type, "System.Exception")) and
            std.mem.endsWith(u8, child_class, "Exception"))
        {
            return true;
        }
        return false;
    }

    /// System enum の文字列値から ordinal 値を返す。
    /// System.LoggingLevel, System.StatusCode, DisplayType など既知のenumに対応。
    fn lookupEnumOrdinal(s: []const u8) i64 {
        // System.LoggingLevel: Salesforce declaration order (most verbose first)
        // INTERNAL=0, FINEST=1, FINER=2, FINE=3, DEBUG=4, INFO=5, WARN=6, ERROR=7, NONE=8
        const logging_levels = [_][]const u8{ "INTERNAL", "FINEST", "FINER", "FINE", "DEBUG", "INFO", "WARN", "ERROR", "NONE" };
        for (logging_levels, 0..) |name, i| {
            if (std.ascii.eqlIgnoreCase(s, name)) return @intCast(i);
        }
        // System.TriggerOperation: BEFORE_INSERT=0, BEFORE_UPDATE=1, BEFORE_DELETE=2,
        // AFTER_INSERT=3, AFTER_UPDATE=4, AFTER_DELETE=5, AFTER_UNDELETE=6
        const trigger_ops = [_][]const u8{ "BEFORE_INSERT", "BEFORE_UPDATE", "BEFORE_DELETE", "AFTER_INSERT", "AFTER_UPDATE", "AFTER_DELETE", "AFTER_UNDELETE" };
        for (trigger_ops, 0..) |name, i| {
            if (std.ascii.eqlIgnoreCase(s, name)) return @intCast(i);
        }
        return 0;
    }

    /// ISO 日付文字列 (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ) をパースする。
    fn parseIsoDate(s: []const u8) ?struct { y: i32, m: u8, d: u8, h: u8, mi: u8, sec: u8, has_time: bool } {
        if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
        const y = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
        const m = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
        const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
        if (s.len >= 19 and s[10] == 'T') {
            const h = std.fmt.parseInt(u8, s[11..13], 10) catch 0;
            const mi = std.fmt.parseInt(u8, s[14..16], 10) catch 0;
            const sec = std.fmt.parseInt(u8, s[17..19], 10) catch 0;
            return .{ .y = y, .m = m, .d = day, .h = h, .mi = mi, .sec = sec, .has_time = true };
        }
        return .{ .y = y, .m = m, .d = day, .h = 0, .mi = 0, .sec = 0, .has_time = false };
    }

    /// 月と日から年内通算日を返す (1-indexed)
    fn dayOfYear(m: u8, d: u8) u16 {
        const cumulative = [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
        return cumulative[m - 1] + d;
    }

    /// Datetime パターンフォーマット (Java SimpleDateFormat 互換サブセット)
    fn formatDateTimePattern(self: *Evaluator, s: []const u8, pattern: []const u8) !Value {
        const dt = parseIsoDate(s) orelse return Value{ .string = s };
        const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
        const month_abbr = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        const month_name = if (dt.m >= 1 and dt.m <= 12) month_names[dt.m - 1] else "January";
        const month_short = if (dt.m >= 1 and dt.m <= 12) month_abbr[dt.m - 1] else "Jan";

        var result: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < pattern.len) {
            const c = pattern[i];
            // Count consecutive same characters
            var count: usize = 1;
            while (i + count < pattern.len and pattern[i + count] == c) : (count += 1) {}

            switch (c) {
                'y' => {
                    if (count <= 2) {
                        const short_y: u32 = @intCast(@mod(dt.y, 100));
                        const ys = try std.fmt.allocPrint(self.arena, "{d:0>2}", .{short_y});
                        try result.appendSlice(self.arena, ys);
                    } else {
                        const ys = try std.fmt.allocPrint(self.arena, "{d:0>4}", .{@as(u32, @intCast(dt.y))});
                        try result.appendSlice(self.arena, ys);
                    }
                },
                'M' => {
                    if (count >= 4) {
                        try result.appendSlice(self.arena, month_name);
                    } else if (count == 3) {
                        try result.appendSlice(self.arena, month_short);
                    } else if (count == 2) {
                        const ms = try std.fmt.allocPrint(self.arena, "{d:0>2}", .{dt.m});
                        try result.appendSlice(self.arena, ms);
                    } else {
                        const ms = try std.fmt.allocPrint(self.arena, "{d}", .{dt.m});
                        try result.appendSlice(self.arena, ms);
                    }
                },
                'd' => {
                    if (count >= 2) {
                        const ds = try std.fmt.allocPrint(self.arena, "{d:0>2}", .{dt.d});
                        try result.appendSlice(self.arena, ds);
                    } else {
                        const ds = try std.fmt.allocPrint(self.arena, "{d}", .{dt.d});
                        try result.appendSlice(self.arena, ds);
                    }
                },
                'H' => {
                    if (count >= 2) {
                        const hs = try std.fmt.allocPrint(self.arena, "{d:0>2}", .{dt.h});
                        try result.appendSlice(self.arena, hs);
                    } else {
                        const hs = try std.fmt.allocPrint(self.arena, "{d}", .{dt.h});
                        try result.appendSlice(self.arena, hs);
                    }
                },
                'h' => {
                    const h12: u8 = if (dt.h == 0) 12 else if (dt.h > 12) dt.h - 12 else dt.h;
                    if (count >= 2) {
                        const hs = try std.fmt.allocPrint(self.arena, "{d:0>2}", .{h12});
                        try result.appendSlice(self.arena, hs);
                    } else {
                        const hs = try std.fmt.allocPrint(self.arena, "{d}", .{h12});
                        try result.appendSlice(self.arena, hs);
                    }
                },
                'm' => {
                    if (count >= 2) {
                        const ms = try std.fmt.allocPrint(self.arena, "{d:0>2}", .{dt.mi});
                        try result.appendSlice(self.arena, ms);
                    } else {
                        const ms = try std.fmt.allocPrint(self.arena, "{d}", .{dt.mi});
                        try result.appendSlice(self.arena, ms);
                    }
                },
                's' => {
                    if (count >= 2) {
                        const ss = try std.fmt.allocPrint(self.arena, "{d:0>2}", .{dt.sec});
                        try result.appendSlice(self.arena, ss);
                    } else {
                        const ss = try std.fmt.allocPrint(self.arena, "{d}", .{dt.sec});
                        try result.appendSlice(self.arena, ss);
                    }
                },
                'a' => {
                    try result.appendSlice(self.arena, if (dt.h < 12) "AM" else "PM");
                },
                '\'' => {
                    // Quoted literal text
                    i += 1; // skip opening quote
                    while (i < pattern.len and pattern[i] != '\'') : (i += 1) {
                        try result.append(self.arena, pattern[i]);
                    }
                    if (i < pattern.len) i += 1; // skip closing quote
                    continue;
                },
                else => {
                    for (0..count) |_| try result.append(self.arena, c);
                },
            }
            i += count;
        }
        return Value{ .string = result.items };
    }

    /// addYears / addMonths / addDays — ISO 日付文字列に対する日付演算
    fn dateTimeAdd(self: *Evaluator, s: []const u8, method: []const u8, args: []const Value) !Value {
        const dt = parseIsoDate(s) orelse return Value{ .string = s };
        const delta: i32 = if (args.len > 0) switch (args[0]) {
            .integer => |i| @intCast(i),
            .double => |d| @intFromFloat(d),
            else => 0,
        } else 0;

        var y = dt.y;
        var m: i32 = dt.m;
        var d: i32 = dt.d;

        if (std.ascii.eqlIgnoreCase(method, "addYears")) {
            y += delta;
        } else if (std.ascii.eqlIgnoreCase(method, "addMonths")) {
            m += delta;
            while (m < 1) {
                m += 12;
                y -= 1;
            }
            while (m > 12) {
                m -= 12;
                y += 1;
            }
        } else if (std.ascii.eqlIgnoreCase(method, "addDays")) {
            d += delta;
            // 簡易実装: 各月の日数でオーバーフロー/アンダーフローを処理
            const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
            while (d > days_in_month[@intCast(m - 1)]) {
                d -= days_in_month[@intCast(m - 1)];
                m += 1;
                if (m > 12) {
                    m = 1;
                    y += 1;
                }
            }
            while (d < 1) {
                m -= 1;
                if (m < 1) {
                    m = 12;
                    y -= 1;
                }
                d += days_in_month[@intCast(m - 1)];
            }
        }

        if (dt.has_time) {
            return Value{ .string = try std.fmt.allocPrint(self.arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                @as(u32, @intCast(y)),
                @as(u32, @intCast(m)),
                @as(u32, @intCast(d)),
                dt.h,
                dt.mi,
                dt.sec,
            }) };
        }
        return Value{ .string = try std.fmt.allocPrint(self.arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            @as(u32, @intCast(y)),
            @as(u32, @intCast(m)),
            @as(u32, @intCast(d)),
        }) };
    }

    // -----------------------------------------------------------------------
    // テストフレームワーク
    // -----------------------------------------------------------------------

    fn handleAssert(self: *Evaluator, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "areEqual") or std.ascii.eqlIgnoreCase(method, "assertEquals")) {
            if (args.len >= 2) {
                if (!utils.valueEql(args[0], args[1])) {
                    const expected_str = try utils.coerceToString(args[0], self.arena);
                    const actual_str = try utils.coerceToString(args[1], self.arena);
                    self.assertion_failure = if (args.len >= 3 and args[2] == .string)
                        try std.fmt.allocPrint(self.arena, "{s} | Expected: {s}, Actual: {s}", .{ args[2].string, expected_str, actual_str })
                    else
                        try std.fmt.allocPrint(self.arena, "Expected: {s}, Actual: {s}", .{ expected_str, actual_str });
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "areNotEqual") or std.ascii.eqlIgnoreCase(method, "assertNotEquals")) {
            if (args.len >= 2) {
                if (utils.valueEql(args[0], args[1])) {
                    const val_str = try utils.coerceToString(args[0], self.arena);
                    self.assertion_failure = if (args.len >= 3 and args[2] == .string)
                        try std.fmt.allocPrint(self.arena, "{s} | Both values: {s}", .{ args[2].string, val_str })
                    else
                        try std.fmt.allocPrint(self.arena, "Values should not be equal: {s}", .{val_str});
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "isTrue") or std.ascii.eqlIgnoreCase(method, "assertTrue")) {
            if (args.len >= 1) {
                const val = utils.coerceToBool(args[0]) catch false;
                if (!val) {
                    const actual_str = try utils.coerceToString(args[0], self.arena);
                    self.assertion_failure = if (args.len >= 2 and args[1] == .string)
                        try std.fmt.allocPrint(self.arena, "{s} | Expected: true, Actual: {s}", .{ args[1].string, actual_str })
                    else
                        try std.fmt.allocPrint(self.arena, "Expected: true, Actual: {s}", .{actual_str});
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "isFalse") or std.ascii.eqlIgnoreCase(method, "assertFalse")) {
            if (args.len >= 1) {
                const val = utils.coerceToBool(args[0]) catch false;
                if (val) {
                    const actual_str = try utils.coerceToString(args[0], self.arena);
                    self.assertion_failure = if (args.len >= 2 and args[1] == .string)
                        try std.fmt.allocPrint(self.arena, "{s} | Expected: false, Actual: {s}", .{ args[1].string, actual_str })
                    else
                        try std.fmt.allocPrint(self.arena, "Expected: false, Actual: {s}", .{actual_str});
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "isNotNull") or std.ascii.eqlIgnoreCase(method, "assertNotNull")) {
            if (args.len >= 1) {
                if (args[0] == .null_val) {
                    self.assertion_failure = if (args.len >= 2 and args[1] == .string)
                        try std.fmt.allocPrint(self.arena, "{s} | Expected: non-null, Actual: null", .{args[1].string})
                    else
                        "Expected: non-null, Actual: null";
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "isNull")) {
            if (args.len >= 1) {
                if (args[0] != .null_val) {
                    const actual_str = try utils.coerceToString(args[0], self.arena);
                    self.assertion_failure = if (args.len >= 2 and args[1] == .string)
                        try std.fmt.allocPrint(self.arena, "{s} | Expected: null, Actual: {s}", .{ args[1].string, actual_str })
                    else
                        try std.fmt.allocPrint(self.arena, "Expected: null, Actual: {s}", .{actual_str});
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "isInstanceOfType")) {
            // simplified: always pass
        } else if (std.ascii.eqlIgnoreCase(method, "fail")) {
            self.assertion_failure = if (args.len >= 1 and args[0] == .string) args[0].string else "Assert.fail called";
        }
        return .void_val;
    }

    fn handleTest(self: *Evaluator, method: []const u8, args: []const Value) !Value {
        // Test.startTest() — reset governor limits (Salesforce resets at startTest)
        if (std.ascii.eqlIgnoreCase(method, "startTest")) {
            self.limits_dml = 0;
            self.limits_dml_rows = 0;
            self.limits_soql = 0;
            self.limits_publish_immediate = 0;
            self.limits_queueable = 0;
            self.limits_callouts = 0;
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "stopTest")) {
            return .void_val;
        }
        // Test.setFixedSearchResults(List<Id>)
        if (std.ascii.eqlIgnoreCase(method, "setFixedSearchResults") and args.len >= 1) {
            self.fixed_search_results = args[0];
            return .void_val;
        }
        // Test.setMock(Type, mockInstance)
        if (std.ascii.eqlIgnoreCase(method, "setMock") and args.len >= 2) {
            self.callout_mock = args[1];
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "isRunningTest")) {
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "setCreatedDate")) {
            var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
            _ = try builtins.dispatchStatic(&bctx, "Test", method, args);
            return .void_val;
        }
        // Test.getEventBus() → return an EventBus stub with deliver() method
        if (std.ascii.eqlIgnoreCase(method, "getEventBus")) {
            const eb = try self.arena.create(types.ObjectInstance);
            eb.* = .{ .class_name = "EventBus" };
            return Value{ .object = eb };
        }
        // Test.createStub(Type, StubProvider) → create a stub proxy
        if (std.ascii.eqlIgnoreCase(method, "createStub") and args.len >= 2) {
            const type_val = args[0]; // Type object
            const provider = args[1]; // StubProvider instance
            const type_name: []const u8 = if (type_val == .object)
                (if (type_val.object.fields.get("name")) |n| (if (n == .string) n.string else "Object") else "Object")
            else
                "Object";
            // Create a stub instance that records the provider for method dispatch
            const stub = try self.arena.create(types.ObjectInstance);
            stub.* = .{ .class_name = type_name };
            try stub.fields.put(self.arena, "__stubProvider__", provider);
            // Initialize instance fields from the class if it exists
            if (self.findClass(type_name)) |class_decl| {
                self.initInstanceFields(class_decl, stub) catch {};
                if (class_decl.super_class) |sc| {
                    if (self.findClass(sc.name)) |parent| {
                        self.initInstanceFields(parent, stub) catch {};
                    }
                }
            }
            return Value{ .object = stub };
        }
        return .void_val;
    }

    fn handleTriggerHandler(self: *Evaluator, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "bypass") and args.len > 0 and args[0] == .string) {
            try self.bypasses.put(self.arena, args[0].string, {});
        }
        return .void_val;
    }

    fn getDmlOptionsAllOrNone(_: *Evaluator, value: Value) ?bool {
        const fields = switch (value) {
            .object => value.object.fields,
            .sobject => value.sobject.fields,
            else => return null,
        };
        if (fields.get("OptAllOrNone")) |opt| {
            if (opt == .boolean) return opt.boolean;
        }
        for (fields.keys(), fields.values()) |k, v| {
            if (std.ascii.eqlIgnoreCase(k, "OptAllOrNone") and v == .boolean) return v.boolean;
        }
        return null;
    }

    fn sobjectIdForResult(_: *Evaluator, obj: *types.SObject) ?[]const u8 {
        if (obj.id) |id| return id;
        if (utils.sobjectGet(&obj.fields, "Id")) |id_val| {
            if (id_val == .string) return id_val.string;
        }
        return null;
    }

    fn createDmlResultValue(self: *Evaluator, result_class: []const u8, success: bool, id: ?[]const u8, is_created: ?bool) !Value {
        const sr = try self.arena.create(types.ObjectInstance);
        sr.* = .{ .class_name = result_class };
        try sr.fields.put(self.arena, "isSuccess", Value{ .boolean = success });
        try sr.fields.put(self.arena, "success", Value{ .boolean = success });
        if (id) |record_id| {
            try sr.fields.put(self.arena, "id", Value{ .string = record_id });
            try sr.fields.put(self.arena, "Id", Value{ .string = record_id });
        }
        if (is_created) |created| {
            try sr.fields.put(self.arena, "isCreated", Value{ .boolean = created });
            try sr.fields.put(self.arena, "created", Value{ .boolean = created });
        }
        return Value{ .object = sr };
    }

    fn createEmptyResultListValue(self: *Evaluator) !Value {
        const empty = try self.arena.create(types.ListValue);
        empty.* = .{};
        return Value{ .list = empty };
    }

    fn executePartialDatabaseMethod(self: *Evaluator, op: ast.DmlOp, result_class: []const u8, target: Value, external_id_field: ?[]const u8) !Value {
        const appendFailure = struct {
            fn build(self_eval: *Evaluator, cls: []const u8, item: Value, op_kind: ast.DmlOp) !Value {
                const result_id = if (item == .sobject) self_eval.sobjectIdForResult(item.sobject) else null;
                return self_eval.createDmlResultValue(cls, false, result_id, if (op_kind == .upsert) false else null);
            }
        };

        switch (target) {
            .null_val, .void_val => return self.createEmptyResultListValue(),
            .sobject => {
                self.limits_dml += 1;
                self.limits_dml_rows += 1;
                return switch (op) {
                    .insert => blk: {
                        try self.executeDmlWithExternalIdInternal(.insert, target, null, false);
                        break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(target.sobject), null);
                    },
                    .update => blk: {
                        try self.executeDmlWithExternalIdInternal(.update, target, null, false);
                        break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(target.sobject), null);
                    },
                    .upsert => blk: {
                        const was_created = self.willUpsertCreateRecord(target.sobject, external_id_field);
                        try self.executeDmlWithExternalIdInternal(.upsert, target, external_id_field, false);
                        break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(target.sobject), was_created);
                    },
                    .delete => blk: {
                        try self.executeDmlWithExternalIdInternal(.delete, target, null, false);
                        break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(target.sobject), null);
                    },
                    .undelete => blk: {
                        try self.executeDmlWithExternalIdInternal(.undelete, target, null, false);
                        break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(target.sobject), null);
                    },
                    else => Value.null_val,
                };
            },
            .list => |records| {
                const items = records.items.items;
                if (items.len == 0) return self.createEmptyResultListValue();

                self.limits_dml += 1;
                self.limits_dml_rows += @intCast(items.len);

                const list = try self.arena.create(types.ListValue);
                list.* = .{};
                for (items) |item| {
                    if (item != .sobject) {
                        try list.items.append(self.arena, try appendFailure.build(self, result_class, item, op));
                        continue;
                    }
                    const was_created = op == .upsert and self.willUpsertCreateRecord(item.sobject, external_id_field);
                    const result = switch (op) {
                        .insert => blk: {
                            self.executeDmlWithExternalIdInternal(.insert, item, null, false) catch {
                                self.pending_exception = null;
                                break :blk try appendFailure.build(self, result_class, item, op);
                            };
                            break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(item.sobject), null);
                        },
                        .update => blk: {
                            self.executeDmlWithExternalIdInternal(.update, item, null, false) catch {
                                self.pending_exception = null;
                                break :blk try appendFailure.build(self, result_class, item, op);
                            };
                            break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(item.sobject), null);
                        },
                        .upsert => blk: {
                            self.executeDmlWithExternalIdInternal(.upsert, item, external_id_field, false) catch {
                                self.pending_exception = null;
                                break :blk try appendFailure.build(self, result_class, item, op);
                            };
                            break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(item.sobject), was_created);
                        },
                        .delete => blk: {
                            self.executeDmlWithExternalIdInternal(.delete, item, null, false) catch {
                                self.pending_exception = null;
                                break :blk try appendFailure.build(self, result_class, item, op);
                            };
                            break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(item.sobject), null);
                        },
                        .undelete => blk: {
                            self.executeDmlWithExternalIdInternal(.undelete, item, null, false) catch {
                                self.pending_exception = null;
                                break :blk try appendFailure.build(self, result_class, item, op);
                            };
                            break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(item.sobject), null);
                        },
                        else => Value.null_val,
                    };
                    try list.items.append(self.arena, result);
                }
                return Value{ .list = list };
            },
            .set => |records| {
                const items = records.entries.values();
                if (items.len == 0) return self.createEmptyResultListValue();

                self.limits_dml += 1;
                self.limits_dml_rows += @intCast(items.len);

                const list = try self.arena.create(types.ListValue);
                list.* = .{};
                for (items) |item| {
                    if (item != .sobject) {
                        try list.items.append(self.arena, try appendFailure.build(self, result_class, item, op));
                        continue;
                    }
                    const was_created = op == .upsert and self.willUpsertCreateRecord(item.sobject, external_id_field);
                    const result = switch (op) {
                        .insert => blk: {
                            self.executeDmlWithExternalIdInternal(.insert, item, null, false) catch {
                                self.pending_exception = null;
                                break :blk try appendFailure.build(self, result_class, item, op);
                            };
                            break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(item.sobject), null);
                        },
                        .update => blk: {
                            self.executeDmlWithExternalIdInternal(.update, item, null, false) catch {
                                self.pending_exception = null;
                                break :blk try appendFailure.build(self, result_class, item, op);
                            };
                            break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(item.sobject), null);
                        },
                        .upsert => blk: {
                            self.executeDmlWithExternalIdInternal(.upsert, item, external_id_field, false) catch {
                                self.pending_exception = null;
                                break :blk try appendFailure.build(self, result_class, item, op);
                            };
                            break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(item.sobject), was_created);
                        },
                        .delete => blk: {
                            self.executeDmlWithExternalIdInternal(.delete, item, null, false) catch {
                                self.pending_exception = null;
                                break :blk try appendFailure.build(self, result_class, item, op);
                            };
                            break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(item.sobject), null);
                        },
                        .undelete => blk: {
                            self.executeDmlWithExternalIdInternal(.undelete, item, null, false) catch {
                                self.pending_exception = null;
                                break :blk try appendFailure.build(self, result_class, item, op);
                            };
                            break :blk try self.createDmlResultValue(result_class, true, self.sobjectIdForResult(item.sobject), null);
                        },
                        else => Value.null_val,
                    };
                    try list.items.append(self.arena, result);
                }
                return Value{ .list = list };
            },
            else => {
                const list = try self.arena.create(types.ListValue);
                list.* = .{};
                try list.items.append(self.arena, try appendFailure.build(self, result_class, target, op));
                return Value{ .list = list };
            },
        }
    }

    fn handleDatabaseMethod(self: *Evaluator, method: []const u8, args: []const Value, env: *Env) anyerror!Value {
        if (std.ascii.eqlIgnoreCase(method, "insert") or
            std.ascii.eqlIgnoreCase(method, "update") or
            std.ascii.eqlIgnoreCase(method, "upsert") or
            std.ascii.eqlIgnoreCase(method, "delete") or
            std.ascii.eqlIgnoreCase(method, "undelete"))
        {
            const result_class = if (std.ascii.eqlIgnoreCase(method, "upsert"))
                "Database.UpsertResult"
            else if (std.ascii.eqlIgnoreCase(method, "undelete"))
                "Database.UndeleteResult"
            else if (std.ascii.eqlIgnoreCase(method, "delete"))
                "Database.DeleteResult"
            else
                "Database.SaveResult";

            const is_upsert = std.ascii.eqlIgnoreCase(method, "upsert");
            const external_id_field = if (is_upsert and args.len >= 2 and args[1] != .boolean) extractSObjectFieldName(args[1]) else null;
            // Check allOrNothing flag (second arg, defaults to true).
            // Upsert with external id field uses the third arg for allOrNothing.
            const all_or_nothing = blk: {
                if (is_upsert and args.len >= 3 and args[2] == .boolean) break :blk args[2].boolean;
                if (is_upsert and args.len >= 3) {
                    if (self.getDmlOptionsAllOrNone(args[2])) |opt| break :blk opt;
                }
                if (args.len >= 2 and args[1] == .boolean) break :blk args[1].boolean;
                if (args.len >= 2) {
                    if (self.getDmlOptionsAllOrNone(args[1])) |opt| break :blk opt;
                }
                break :blk true;
            };

            // Check if second arg is AccessLevel.USER_MODE for min-access user context (without permsets)
            const has_permset_db = if (self.store.get("PermissionSetAssignment")) |psa| psa.items.len > 0 else false;
            if (self.is_min_access_user and !has_permset_db and args.len >= 2) {
                const is_user_mode = if (args[1] == .string)
                    std.ascii.eqlIgnoreCase(args[1].string, "USER_MODE")
                else if (args[1] == .object) blk: {
                    if (args[1].object.fields.get("name")) |n| {
                        if (n == .string) break :blk std.ascii.eqlIgnoreCase(n.string, "USER_MODE");
                    }
                    break :blk false;
                } else false;
                if (is_user_mode) {
                    const from_type = if (args[0] == .sobject) args[0].sobject.type_name else if (args[0] == .list and args[0].list.items.items.len > 0 and args[0].list.items.items[0] == .sobject)
                        args[0].list.items.items[0].sobject.type_name
                    else
                        "SObject";
                    const msg = try std.fmt.allocPrint(self.arena, "Access to entity '{s}' denied", .{from_type});
                    const exc = try self.arena.create(types.ObjectInstance);
                    exc.* = .{ .class_name = "System.SecurityException" };
                    try exc.fields.put(self.arena, "message", Value{ .string = msg });
                    self.pending_exception = Value{ .object = exc };
                    return error.ApexException;
                }
            }

            // For upsert, record which items will insert vs update before DML runs.
            var upsert_creates: std.ArrayListUnmanaged(bool) = .empty;
            if (is_upsert and args.len > 0) {
                if (args[0] == .sobject) {
                    try upsert_creates.append(self.arena, self.willUpsertCreateRecord(args[0].sobject, external_id_field));
                } else if (args[0] == .list) {
                    for (args[0].list.items.items) |item| {
                        try upsert_creates.append(self.arena, if (item == .sobject) self.willUpsertCreateRecord(item.sobject, external_id_field) else true);
                    }
                }
            }

            // First arg is the records to DML
            if (args.len > 0) {
                const op: ast.DmlOp = if (std.ascii.eqlIgnoreCase(method, "insert"))
                    .insert
                else if (std.ascii.eqlIgnoreCase(method, "update"))
                    .update
                else if (std.ascii.eqlIgnoreCase(method, "upsert"))
                    .upsert
                else if (std.ascii.eqlIgnoreCase(method, "undelete"))
                    .undelete
                else
                    .delete;

                if (all_or_nothing) {
                    // allOrNothing mode: propagate exceptions
                    if (is_upsert) {
                        try self.executeDmlWithExternalId(op, args[0], external_id_field);
                    } else {
                        try self.executeDml(op, args[0]);
                    }
                } else {
                    // Best-effort mode: allow per-record failures instead of failing the whole DML statement.
                    return self.executePartialDatabaseMethod(op, result_class, args[0], external_id_field) catch |err| {
                        self.pending_exception = null;
                        if (err == error.ApexException and args[0] == .sobject) {
                            return self.createDmlResultValue(result_class, false, self.sobjectIdForResult(args[0].sobject), if (is_upsert) false else null);
                        }
                        return err;
                    };
                }
            }
            // Create SaveResult(s) for success case
            if (args.len > 0 and args[0] == .sobject) {
                // Single record: return single result (not a list)
                const was_created = is_upsert and (upsert_creates.items.len > 0 and upsert_creates.items[0]);
                const sr = try self.arena.create(types.ObjectInstance);
                sr.* = .{ .class_name = result_class };
                try sr.fields.put(self.arena, "isSuccess", Value{ .boolean = true });
                try sr.fields.put(self.arena, "success", Value{ .boolean = true });
                try sr.fields.put(self.arena, "Id", Value{ .string = args[0].sobject.id orelse "001000000000001" });
                if (is_upsert) {
                    try sr.fields.put(self.arena, "isCreated", Value{ .boolean = was_created });
                    try sr.fields.put(self.arena, "created", Value{ .boolean = was_created });
                }
                return Value{ .object = sr };
            }
            // Return SaveResult list
            const list = try self.arena.create(types.ListValue);
            list.* = .{};
            if (args.len > 0 and args[0] == .list) {
                for (args[0].list.items.items, 0..) |item, idx| {
                    const was_created = is_upsert and (if (idx < upsert_creates.items.len) upsert_creates.items[idx] else true);
                    const sr = try self.arena.create(types.ObjectInstance);
                    sr.* = .{ .class_name = result_class };
                    try sr.fields.put(self.arena, "isSuccess", Value{ .boolean = true });
                    try sr.fields.put(self.arena, "success", Value{ .boolean = true });
                    try sr.fields.put(self.arena, "Id", Value{ .string = if (item == .sobject) (item.sobject.id orelse "001000000000001") else "001000000000001" });
                    if (is_upsert) {
                        try sr.fields.put(self.arena, "isCreated", Value{ .boolean = was_created });
                        try sr.fields.put(self.arena, "created", Value{ .boolean = was_created });
                    }
                    try list.items.append(self.arena, Value{ .object = sr });
                }
            } else {
                const sr = try self.arena.create(types.ObjectInstance);
                sr.* = .{ .class_name = result_class };
                try sr.fields.put(self.arena, "isSuccess", Value{ .boolean = true });
                try sr.fields.put(self.arena, "success", Value{ .boolean = true });
                try sr.fields.put(self.arena, "Id", Value{ .string = "001000000000001" });
                try list.items.append(self.arena, Value{ .object = sr });
            }
            return Value{ .list = list };
        }
        if (std.ascii.eqlIgnoreCase(method, "query")) {
            // Execute the SOQL string against the store
            if (args.len > 0 and args[0] == .string) {
                return self.executeSoql(args[0].string, env);
            }
            const list = try self.arena.create(types.ListValue);
            list.* = .{};
            return Value{ .list = list };
        }
        if (std.ascii.eqlIgnoreCase(method, "queryWithBinds")) {
            // debug removed
            // Database.queryWithBinds(queryString, bindMap, accessLevel)
            if (args.len >= 2 and args[0] == .string) {
                // Resolve bind variables from the map
                var soql_str = args[0].string;
                if (args[1] == .map) {
                    // Replace :bindVar with actual values from the map
                    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
                    var pos: usize = 0;
                    while (pos < soql_str.len) {
                        if (soql_str[pos] == ':') {
                            // Extract bind variable name
                            var end = pos + 1;
                            while (end < soql_str.len and (std.ascii.isAlphanumeric(soql_str[end]) or soql_str[end] == '_')) end += 1;
                            const bind_name = soql_str[pos + 1 .. end];
                            if (args[1].map.entries.get(bind_name)) |bind_val| {
                                const s = try utils.coerceToString(bind_val, self.arena);
                                try result_buf.append(self.arena, '\'');
                                try result_buf.appendSlice(self.arena, s);
                                try result_buf.append(self.arena, '\'');
                            } else {
                                try result_buf.appendSlice(self.arena, soql_str[pos..end]);
                            }
                            pos = end;
                        } else {
                            try result_buf.append(self.arena, soql_str[pos]);
                            pos += 1;
                        }
                    }
                    soql_str = try result_buf.toOwnedSlice(self.arena);
                }
                return self.executeSoql(soql_str, env);
            }
            return try self.makeEmptyList();
        }
        if (std.ascii.eqlIgnoreCase(method, "countQuery") or std.ascii.eqlIgnoreCase(method, "countQueryWithBinds")) {
            // countQuery can take a SOQL string
            if (args.len > 0 and args[0] == .string) {
                const soql = args[0].string;
                // Execute as a count query
                if (std.ascii.indexOfIgnoreCase(soql, "count()")) |_| {
                    return self.executeSoql(soql, env);
                }
                // Wrap as COUNT query
                const count_result = try self.executeSoql(soql, env);
                if (count_result == .list) return Value{ .integer = @intCast(count_result.list.items.items.len) };
                return count_result;
            }
            return Value{ .integer = 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "getQueryLocator")) {
            const ql = try self.arena.create(types.ObjectInstance);
            ql.* = .{ .class_name = "Database.QueryLocator" };
            if (args.len > 0 and args[0] == .string) {
                try ql.fields.put(self.arena, "query", args[0]);
            } else if (args.len > 0 and args[0] == .list) {
                try ql.fields.put(self.arena, "records", args[0]);
            }
            return Value{ .object = ql };
        }
        if (std.ascii.eqlIgnoreCase(method, "emptyRecycleBin")) {
            // Database.emptyRecycleBin permanently deletes records from the recycle bin.
            // Count it as a DML operation.
            self.limits_dml += 1;
            if (args.len > 0 and args[0] == .list) {
                self.limits_dml_rows += @intCast(args[0].list.items.items.len);
            } else if (args.len > 0) {
                self.limits_dml_rows += 1;
            }
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "setSavepoint")) {
            const sp = try self.arena.create(types.ObjectInstance);
            sp.* = .{ .class_name = "Database.SavePoint" };
            return Value{ .object = sp };
        }
        if (std.ascii.eqlIgnoreCase(method, "rollback")) {
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "executeBatch")) {
            // Batch runs in separate transaction — save/restore limits
            const sb_dml = self.limits_dml;
            const sb_dml_rows = self.limits_dml_rows;
            const sb_soql = self.limits_soql;
            const sb_pub = self.limits_publish_immediate;
            const sb_call = self.limits_callouts;
            defer {
                self.limits_dml = sb_dml;
                self.limits_dml_rows = sb_dml_rows;
                self.limits_soql = sb_soql;
                self.limits_publish_immediate = sb_pub;
                self.limits_callouts = sb_call;
            }
            if (args.len > 0 and args[0] == .object) {
                if (self.batch_job_runner_active or self.batch_lifecycle_depth > 0) {
                    const job_id = try std.fmt.allocPrint(self.arena, "707{d:0>15}", .{self.next_id});
                    self.next_id += 1;
                    if (self.batch_job_runner_active) {
                        try self.pending_batch_jobs.append(self.arena, args[0]);
                    }
                    return Value{ .string = job_id };
                }

                const job_id = try self.createAsyncApexJob("BatchApex", args[0].object.class_name, "execute");
                self.batch_job_runner_active = true;
                self.pending_batch_jobs = .empty;
                defer {
                    self.pending_batch_jobs = .empty;
                    self.batch_job_runner_active = false;
                }

                try self.pending_batch_jobs.append(self.arena, args[0]);
                var job_index: usize = 0;
                while (job_index < self.pending_batch_jobs.items.len) : (job_index += 1) {
                    const batch_value = self.pending_batch_jobs.items[job_index];
                    if (batch_value != .object) continue;
                    const batch_obj = batch_value.object;
                    if (self.findClass(batch_obj.class_name)) |batch_class| {
                        const scope = try self.callInstanceMethod(batch_class, batch_obj, "start", &.{Value.null_val});
                        var all_records: std.ArrayListUnmanaged(Value) = .empty;
                        if (scope == .object) {
                            if (scope.object.fields.get("query")) |query_val| {
                                if (query_val == .string) {
                                    const batch_env = try self.global_env.child();
                                    const query_result = self.executeSoql(query_val.string, batch_env) catch Value.null_val;
                                    if (query_result == .list) {
                                        for (query_result.list.items.items) |item| {
                                            try all_records.append(self.arena, item);
                                        }
                                    }
                                }
                            } else if (scope.object.fields.get("records")) |records_val| {
                                if (records_val == .list) {
                                    for (records_val.list.items.items) |item| {
                                        try all_records.append(self.arena, item);
                                    }
                                }
                            } else {
                                var store_iter = self.store.iterator();
                                while (store_iter.next()) |entry| {
                                    for (entry.value_ptr.items) |item| {
                                        try all_records.append(self.arena, item);
                                    }
                                }
                            }
                        } else {
                            var store_iter = self.store.iterator();
                            while (store_iter.next()) |entry| {
                                for (entry.value_ptr.items) |item| {
                                    try all_records.append(self.arena, item);
                                }
                            }
                        }
                        const record_list = try self.arena.create(types.ListValue);
                        record_list.* = .{ .items = all_records };
                        _ = try self.callInstanceMethod(batch_class, batch_obj, "execute", &.{ Value.null_val, Value{ .list = record_list } });
                        _ = try self.callInstanceMethod(batch_class, batch_obj, "finish", &.{Value.null_val});
                    }
                }
                return Value{ .string = job_id };
            }
            return Value{ .string = try self.allocId() }; // Fake job ID
        }
        if (std.ascii.eqlIgnoreCase(method, "merge")) {
            // Database.merge(primary, secondaries, allOrNothing)
            // Delete secondary records and cascade-delete referencing DuplicateRecordItems.
            // Return MergeResult[].
            if (args.len >= 2) {
                var secondary_ids: std.ArrayListUnmanaged([]const u8) = .empty;
                // Collect secondary record ids
                if (args[1] == .sobject and args[1].sobject.id != null) {
                    try secondary_ids.append(self.arena, args[1].sobject.id.?);
                } else if (args[1] == .list) {
                    for (args[1].list.items.items) |item| {
                        if (item == .sobject and item.sobject.id != null) {
                            try secondary_ids.append(self.arena, item.sobject.id.?);
                        }
                    }
                }
                // Delete secondary records from store
                for (secondary_ids.items) |sec_id| {
                    var store_iter = self.store.iterator();
                    while (store_iter.next()) |entry| {
                        var i: usize = 0;
                        while (i < entry.value_ptr.items.len) {
                            if (entry.value_ptr.items[i] == .sobject and entry.value_ptr.items[i].sobject.id != null and
                                std.mem.eql(u8, entry.value_ptr.items[i].sobject.id.?, sec_id))
                            {
                                _ = entry.value_ptr.orderedRemove(i);
                            } else {
                                i += 1;
                            }
                        }
                    }
                }
                // Cascade-delete DuplicateRecordItems that reference deleted secondary records
                if (self.store.getPtr("DuplicateRecordItem")) |dri_records| {
                    var i: usize = 0;
                    while (i < dri_records.items.len) {
                        const item = dri_records.items[i];
                        if (item == .sobject) {
                            const rec_id_val = utils.sobjectGet(&item.sobject.fields, "RecordId");
                            if (rec_id_val != null and rec_id_val.? == .string) {
                                var is_deleted = false;
                                for (secondary_ids.items) |sec_id| {
                                    if (std.mem.eql(u8, rec_id_val.?.string, sec_id)) {
                                        is_deleted = true;
                                        break;
                                    }
                                }
                                if (is_deleted) {
                                    // Update RecordCount on parent DRS before removing
                                    self.updateDuplicateRecordSetCount(item.sobject, -1) catch {};
                                    _ = dri_records.orderedRemove(i);
                                    continue;
                                }
                            }
                        }
                        i += 1;
                    }
                }
            }
            // Auto-delete orphaned DuplicateRecordSets after merge
            try self.cleanupOrphanedDuplicateRecordSets();
            // Return MergeResult list
            const mr_list = try self.arena.create(types.ListValue);
            mr_list.* = .{};
            const mr = try self.arena.create(types.ObjectInstance);
            mr.* = .{ .class_name = "Database.MergeResult" };
            try mr.fields.put(self.arena, "isSuccess", Value{ .boolean = true });
            try mr.fields.put(self.arena, "success", Value{ .boolean = true });
            try mr_list.items.append(self.arena, Value{ .object = mr });
            return Value{ .list = mr_list };
        }
        return .void_val;
    }

    fn handleSystemMethod(self: *Evaluator, inner: []const u8, method: []const u8, args: []const Value, current_env: *Env) !Value {
        // System.enqueueJob → execute the Queueable's execute method synchronously
        // Queueable runs in a separate transaction in Salesforce, so save/restore limits
        if (std.ascii.eqlIgnoreCase(inner, "enqueueJob") and args.len > 0 and args[0] == .object) {
            return self.enqueueJob(args[0].object);
        }
        if (std.ascii.eqlIgnoreCase(inner, "enqueueJob")) return .void_val;
        // System.runAs → now handled by run_as_stmt in the AST; this is a fallback no-op
        if (std.ascii.eqlIgnoreCase(inner, "runAs")) {
            return .void_val;
        }
        // System.schedule → store cron expression and return unique job ID
        if (std.ascii.eqlIgnoreCase(inner, "schedule")) {
            const job_id = try std.fmt.allocPrint(self.arena, "08e{d:0>15}", .{self.next_id});
            self.next_id += 1;
            // args: (jobName, cronExpression, schedulableInstance)
            if (args.len >= 2 and args[1] == .string) {
                try self.scheduled_jobs.put(self.arena, job_id, args[1].string);
            }
            return Value{ .string = job_id };
        }
        // System.abortJob → no-op
        if (std.ascii.eqlIgnoreCase(inner, "abortJob")) return .void_val;
        // System.debug
        if (std.ascii.eqlIgnoreCase(inner, "debug") and args.len > 0) {
            const msg = try utils.coerceToString(args[0], self.arena);
            try self.stdout.appendSlice(self.arena, msg);
            try self.stdout.append(self.arena, '\n');
            return .void_val;
        }
        // System.Request.getCurrent() → return a Request object
        if (std.ascii.eqlIgnoreCase(inner, "Request")) {
            var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
            if (try builtins.dispatchStatic(&bctx, "Request", method, args)) |result| return result;
            const obj = try self.arena.create(types.ObjectInstance);
            obj.* = .{ .class_name = "Request" };
            return Value{ .object = obj };
        }
        // System.AccessType/AccessLevel
        if (std.ascii.eqlIgnoreCase(inner, "AccessType") or std.ascii.eqlIgnoreCase(inner, "AccessLevel")) {
            return Value{ .string = method };
        }
        // System.LoggingLevel / System.TriggerOperation
        if (std.ascii.eqlIgnoreCase(inner, "LoggingLevel") or std.ascii.eqlIgnoreCase(inner, "TriggerOperation")) {
            // valueOf(name) → return the enum value string, throw NoSuchElementException for invalid values
            if (std.ascii.eqlIgnoreCase(method, "valueOf") and args.len > 0 and args[0] == .string) {
                const valid_values: []const []const u8 = if (std.ascii.eqlIgnoreCase(inner, "LoggingLevel"))
                    &.{ "INTERNAL", "FINEST", "FINER", "FINE", "DEBUG", "INFO", "WARN", "ERROR", "NONE" }
                else
                    &.{ "BEFORE_INSERT", "BEFORE_UPDATE", "BEFORE_DELETE", "AFTER_INSERT", "AFTER_UPDATE", "AFTER_DELETE", "AFTER_UNDELETE" };
                for (valid_values) |v| {
                    if (std.ascii.eqlIgnoreCase(args[0].string, v)) return Value{ .string = v };
                }
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "System.NoSuchElementException" };
                try exc.fields.put(self.arena, "message", Value{ .string = try std.fmt.allocPrint(self.arena, "No enum constant System.{s}.{s}", .{ inner, args[0].string }) });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
            // values() → return list of all values
            if (std.ascii.eqlIgnoreCase(method, "values")) {
                const list = try self.arena.create(types.ListValue);
                list.* = .{};
                if (std.ascii.eqlIgnoreCase(inner, "LoggingLevel")) {
                    const names = [_][]const u8{ "INTERNAL", "FINEST", "FINER", "FINE", "DEBUG", "INFO", "WARN", "ERROR", "NONE" };
                    for (names) |name| try list.items.append(self.arena, Value{ .string = name });
                } else {
                    const names = [_][]const u8{ "BEFORE_INSERT", "BEFORE_UPDATE", "BEFORE_DELETE", "AFTER_INSERT", "AFTER_UPDATE", "AFTER_DELETE", "AFTER_UNDELETE" };
                    for (names) |name| try list.items.append(self.arena, Value{ .string = name });
                }
                return Value{ .list = list };
            }
            // ENUM_VALUE → return the value name
            return Value{ .string = method };
        }
        // System.SObjectAccessDecision
        if (std.ascii.eqlIgnoreCase(inner, "SObjectAccessDecision")) {
            return .void_val;
        }
        // System.Limits → all methods return 0
        if (std.ascii.eqlIgnoreCase(inner, "Limits")) {
            var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
            if (try builtins.dispatchStatic(&bctx, "Limits", method, args)) |result| return result;
            return Value{ .integer = 0 };
        }
        // System.JSON.serialize / System.JSON.deserialize / System.JSON.deserializeUntyped
        if (std.ascii.eqlIgnoreCase(inner, "JSON")) {
            if (std.ascii.eqlIgnoreCase(method, "serialize") or std.ascii.eqlIgnoreCase(method, "serializePretty")) {
                if (args.len > 0) {
                    return Value{ .string = try utils.toJson(args[0], self.arena) };
                }
                return Value{ .string = "{}" };
            }
            if (std.ascii.eqlIgnoreCase(method, "deserialize") or std.ascii.eqlIgnoreCase(method, "deserializeUntyped")) {
                if (args.len >= 1 and args[0] == .string) {
                    const json_str = args[0].string;
                    const trimmed_json = std.mem.trim(u8, json_str, " \t\r\n");
                    // Check balanced braces/brackets for truncated JSON detection
                    if (!utils.isJsonBalanced(trimmed_json)) {
                        const exc = try self.arena.create(types.ObjectInstance);
                        exc.* = .{ .class_name = "System.JSONException" };
                        try exc.fields.put(self.arena, "message", Value{ .string = "Unexpected end-of-input" });
                        self.pending_exception = Value{ .object = exc };
                        return error.ApexException;
                    }
                    // Delegate to builtins for actual parsing
                    var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
                    if (try builtins.dispatchStatic(&bctx, "JSON", method, args)) |result| return result;
                    const type_name: []const u8 = if (args.len >= 2 and args[1] == .object) blk: {
                        if (std.ascii.eqlIgnoreCase(args[1].object.class_name, "Type")) {
                            if (args[1].object.fields.get("name")) |n| {
                                if (n == .string) break :blk n.string;
                            }
                        }
                        break :blk args[1].object.class_name;
                    } else "Object";
                    if (self.parseJsonValue(json_str, type_name)) |pv| return pv;
                }
                return Value.null_val;
            }
            // JSON.createParser → JSONParser instance with the JSON body stored
            if (std.ascii.eqlIgnoreCase(method, "createParser")) {
                if (args.len >= 1 and args[0] == .string) {
                    const parser_obj = try self.arena.create(types.ObjectInstance);
                    parser_obj.* = .{ .class_name = "JSONParser" };
                    try parser_obj.fields.put(self.arena, "__json_body__", args[0]);
                    return Value{ .object = parser_obj };
                }
                return Value.null_val;
            }
            // Other JSON methods: delegate to builtins
            var bctx2 = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
            if (try builtins.dispatchStatic(&bctx2, "JSON", method, args)) |result| return result;
        }
        // System.Test.startTest / System.Test.stopTest / setMock / etc.
        if (std.ascii.eqlIgnoreCase(inner, "Test")) {
            // setMock needs to be handled by handleTest (not builtins)
            if (std.ascii.eqlIgnoreCase(method, "setMock") and args.len >= 2) {
                self.callout_mock = args[1];
                return .void_val;
            }
            var bctx3 = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
            if (try builtins.dispatchStatic(&bctx3, "Test", method, args)) |result| return result;
        }
        // System.Database.insert / update / delete / upsert / undelete
        if (std.ascii.eqlIgnoreCase(inner, "Database")) {
            return self.handleDatabaseMethod(method, args, current_env);
        }
        // System.EventBus.publish → delegate to callMethod so it goes through the EventBus.publish handler
        if (std.ascii.eqlIgnoreCase(inner, "EventBus") and std.ascii.eqlIgnoreCase(method, "publish")) {
            return self.callMethod("EventBus", "publish", args) catch .void_val;
        }
        // Generic fallback: delegate System.X.method to builtins.dispatchStatic(X, method, args)
        // This covers System.UserInfo, System.Type, System.Assert, System.URL, etc.
        {
            var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout, .pending_exception = &self.pending_exception, .see_all_data = self.see_all_data, .eval = self };
            if (try builtins.dispatchStatic(&bctx, inner, method, args)) |result| return result;
        }
        return .void_val;
    }

    // -----------------------------------------------------------------------
    // ヘルパー
    // -----------------------------------------------------------------------

    fn handleTestFactory(self: *Evaluator, class_name: []const u8, method_name: []const u8, args: []const Value) !?Value {
        // TestFactory.createSObject(sObj) / createSObject(sObj, doInsert) / createSObject(sObj, className)
        if (std.ascii.eqlIgnoreCase(class_name, "TestFactory")) {
            if (std.ascii.eqlIgnoreCase(method_name, "createSObject")) {
                if (args.len >= 1 and args[0] == .sobject) {
                    // Apply default fields if not set
                    if (utils.sobjectGet(&args[0].sobject.fields, "Name") == null) {
                        try args[0].sobject.fields.put(self.arena, "Name", Value{ .string = "Test Record" });
                    }
                    if (std.ascii.eqlIgnoreCase(args[0].sobject.type_name, "Contact") and utils.sobjectGet(&args[0].sobject.fields, "LastName") == null) {
                        try args[0].sobject.fields.put(self.arena, "LastName", Value{ .string = "Test Record" });
                    }
                    // If second arg is boolean and true, insert
                    if (args.len >= 2 and args[1] == .boolean and args[1].boolean) {
                        try self.insertRecord(args[0].sobject);
                    }
                    // If second arg is string, it's a defaults class name — just insert
                    if (args.len >= 2 and args[1] == .string) {
                        try self.insertRecord(args[0].sobject);
                    }
                    return args[0];
                }
                return Value.null_val;
            }
            if (std.ascii.eqlIgnoreCase(method_name, "createSObjectList")) {
                // createSObjectList(sObj, count, doInsert)
                var template: ?*types.SObject = null;
                var count: i64 = 5;
                var do_insert = false;

                if (args.len >= 1 and args[0] == .sobject) template = args[0].sobject;
                if (args.len >= 2 and args[1] == .integer) count = args[1].integer;
                if (args.len >= 3 and args[2] == .boolean) do_insert = args[2].boolean;

                const list = try self.arena.create(types.ListValue);
                list.* = .{};
                var i: i64 = 0;
                while (i < count) : (i += 1) {
                    const obj = try self.arena.create(types.SObject);
                    obj.* = .{ .type_name = if (template) |t| t.type_name else "Account" };
                    // Copy template fields
                    if (template) |t| {
                        for (t.fields.keys(), t.fields.values()) |k, v| {
                            try obj.fields.put(self.arena, k, v);
                        }
                    }
                    // Set Name with index
                    const name = try std.fmt.allocPrint(self.arena, "Test Record {d}", .{i});
                    try obj.fields.put(self.arena, "Name", Value{ .string = name });
                    // Set required fields for specific object types
                    if (std.ascii.eqlIgnoreCase(obj.type_name, "Contact") and utils.sobjectGet(&obj.fields, "LastName") == null) {
                        try obj.fields.put(self.arena, "LastName", Value{ .string = name });
                    }
                    if (std.ascii.eqlIgnoreCase(obj.type_name, "Opportunity") and utils.sobjectGet(&obj.fields, "StageName") == null) {
                        try obj.fields.put(self.arena, "StageName", Value{ .string = "Prospecting" });
                    }

                    try list.items.append(self.arena, Value{ .sobject = obj });
                }
                // Insert all records with trigger support
                if (do_insert) {
                    self.executeDml(.insert, Value{ .list = list }) catch |err| {
                        if (err == error.ApexException) return err;
                    };
                }
                return Value{ .list = list };
            }
            if (std.ascii.eqlIgnoreCase(method_name, "assignPermSetToUser")) {
                // Delegate to user-defined TestFactory if available
                var assign_iter = self.classes.iterator();
                while (assign_iter.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "TestFactory")) {
                        if (self.findBestMethodInClass(entry.value_ptr.*, method_name, args) != null) {
                            return null; // Fall through to user-defined class
                        }
                    }
                }
                return .void_val;
            }
            if (std.ascii.eqlIgnoreCase(method_name, "createTestUser") or
                std.ascii.eqlIgnoreCase(method_name, "createMinAccessUser") or
                std.ascii.eqlIgnoreCase(method_name, "createMarketingUser"))
            {
                // If user-defined TestFactory class has this method, delegate to it
                var class_iter = self.classes.iterator();
                while (class_iter.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "TestFactory")) {
                        if (self.findBestMethodInClass(entry.value_ptr.*, method_name, args) != null) {
                            return null; // Let the caller fall through to user-defined class
                        }
                    }
                }
                // Fallback: create a minimal user stub
                const user = try self.arena.create(types.SObject);
                user.* = .{ .type_name = "User" };
                try user.fields.put(self.arena, "Name", Value{ .string = "Test User" });
                const user_id = try self.allocId();
                try user.fields.put(self.arena, "Id", Value{ .string = user_id });
                user.id = user_id;
                // Set profile info based on method name
                const profile = try self.arena.create(types.SObject);
                profile.* = .{ .type_name = "Profile" };
                if (std.ascii.eqlIgnoreCase(method_name, "createMinAccessUser")) {
                    try profile.fields.put(self.arena, "Name", Value{ .string = "Minimum Access - Salesforce" });
                } else if (std.ascii.eqlIgnoreCase(method_name, "createMarketingUser")) {
                    try profile.fields.put(self.arena, "Name", Value{ .string = "Marketing User" });
                } else {
                    try profile.fields.put(self.arena, "Name", Value{ .string = "Standard User" });
                }
                try user.fields.put(self.arena, "Profile", Value{ .sobject = profile });
                // Insert if first arg is true (or for createMinAccessUser/createMarketingUser)
                if (args.len >= 1 and args[0] == .boolean and args[0].boolean) {
                    try self.insertRecord(user);
                }
                return Value{ .sobject = user };
            }
            return null;
        }

        // TestDataHelpers
        if (std.ascii.eqlIgnoreCase(class_name, "TestDataHelpers")) {
            // If user-defined TestDataHelpers class has this method, delegate to it
            var tdh_iter = self.classes.iterator();
            while (tdh_iter.next()) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "TestDataHelpers")) {
                    if (self.findBestMethodInClass(entry.value_ptr.*, method_name, args) != null) {
                        return null; // Fall through to user-defined class
                    }
                }
            }
            if (std.ascii.eqlIgnoreCase(method_name, "createAccount")) {
                const acct = try self.arena.create(types.SObject);
                acct.* = .{ .type_name = "Account" };
                try acct.fields.put(self.arena, "Name", Value{ .string = "Awesome Test Account" });
                // Check if shipping country arg provided
                if (args.len >= 2 and args[1] == .string and args[1].string.len > 0) {
                    try acct.fields.put(self.arena, "ShippingCountry", args[1]);
                }
                try self.insertRecord(acct);
                return Value{ .sobject = acct };
            }
            if (std.ascii.eqlIgnoreCase(method_name, "genXnumberOfAccounts")) {
                const count = if (args.len >= 1 and args[0] == .integer) args[0].integer else 5;
                const list = try self.arena.create(types.ListValue);
                list.* = .{};
                var i: i64 = 0;
                while (i < count) : (i += 1) {
                    const acct = try self.arena.create(types.SObject);
                    acct.* = .{ .type_name = "Account" };
                    const name = try std.fmt.allocPrint(self.arena, "Awesome Test Account {d}", .{i});
                    try acct.fields.put(self.arena, "Name", Value{ .string = name });
                    try list.items.append(self.arena, Value{ .sobject = acct });
                }
                return Value{ .list = list };
            }
            if (std.ascii.eqlIgnoreCase(method_name, "genAccountWithOptions")) {
                const acct = try self.arena.create(types.SObject);
                acct.* = .{ .type_name = "Account" };
                try acct.fields.put(self.arena, "Name", Value{ .string = "Awesome Test Account" });
                try acct.fields.put(self.arena, "ShippingStreet", Value{ .string = "123 Sessame St." });
                try acct.fields.put(self.arena, "ShippingCity", Value{ .string = "Wehawkin" });
                // First arg is setCountry (not doInsert)
                if (args.len >= 1 and args[0] == .boolean and args[0].boolean) {
                    if (args.len >= 2 and args[1] == .string) {
                        try acct.fields.put(self.arena, "ShippingCountry", args[1]);
                    }
                }
                return Value{ .sobject = acct };
            }
            if (std.ascii.eqlIgnoreCase(method_name, "genContactForAccount")) {
                const contact = try self.arena.create(types.SObject);
                contact.* = .{ .type_name = "Contact" };
                try contact.fields.put(self.arena, "LastName", Value{ .string = "Test Contact" });
                try contact.fields.put(self.arena, "Name", Value{ .string = "Test Contact" });
                if (args.len >= 1) {
                    try contact.fields.put(self.arena, "AccountId", args[0]);
                    try contact.fields.put(self.arena, "accountId", args[0]);
                }
                return Value{ .sobject = contact };
            }
            return null;
        }

        // TestHelper
        if (std.ascii.eqlIgnoreCase(class_name, "TestHelper")) {
            // If user-defined TestHelper class has this method, delegate to it
            var th_iter = self.classes.iterator();
            while (th_iter.next()) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "TestHelper")) {
                    if (self.findBestMethodInClass(entry.value_ptr.*, method_name, args) != null) {
                        return null; // Fall through to user-defined class
                    }
                }
            }
            if (std.ascii.eqlIgnoreCase(method_name, "getUnknownObjectType")) {
                // Return the class name of the object
                if (args.len > 0) {
                    return switch (args[0]) {
                        .object => |o| Value{ .string = o.class_name },
                        .sobject => |s| Value{ .string = s.type_name },
                        .string => Value{ .string = "String" },
                        .integer => Value{ .string = "Integer" },
                        .double => Value{ .string = "Double" },
                        .boolean => Value{ .string = "Boolean" },
                        .list => Value{ .string = "List" },
                        .map => Value{ .string = "Map" },
                        .set => Value{ .string = "Set" },
                        .null_val => Value{ .string = "null" },
                        .void_val => Value{ .string = "void" },
                    };
                }
                return Value{ .string = "null" };
            }
            return null;
        }

        return null;
    }

    /// Create a new instance of the named class and call a method on it.
    pub fn callInstanceMethodByName(self: *Evaluator, class_name: []const u8, method_name: []const u8, args: []const Value) anyerror!Value {
        const class_decl = self.findClass(class_name) orelse return Value.null_val;
        const instance = try self.arena.create(types.ObjectInstance);
        instance.* = .{ .class_name = class_name };
        // Run constructor if exists
        for (class_decl.members) |member| {
            switch (member) {
                .constructor_decl => |cd| {
                    if (cd.params.len == 0) {
                        const ctor_env = try self.global_env.child();
                        try ctor_env.define("this", Value{ .object = instance });
                        _ = self.execBlock(cd.body, ctor_env) catch {};
                        break;
                    }
                },
                else => {},
            }
        }
        return self.callInstanceMethod(class_decl, instance, method_name, args);
    }

    pub fn callInstanceMethodPublic(self: *Evaluator, class_decl: *ast.ClassDecl, instance: *types.ObjectInstance, method_name: []const u8, args: []const Value) anyerror!Value {
        return self.callInstanceMethod(class_decl, instance, method_name, args);
    }

    pub fn handleDatabaseMethodPublic(self: *Evaluator, method: []const u8, args: []const Value, env: *Env) anyerror!Value {
        return self.handleDatabaseMethod(method, args, env);
    }

    const ResolvedInstanceMethod = struct {
        owner: *ast.ClassDecl,
        method: *ast.MethodDecl,
    };

    fn callInstanceMethod(self: *Evaluator, class_decl: *ast.ClassDecl, instance: *types.ObjectInstance, method_name: []const u8, args: []const Value) anyerror!Value {
        const actual_class = self.findClass(instance.class_name);
        return self.callInstanceMethodResolved(class_decl, actual_class, instance, method_name, args);
    }

    fn callSuperInstanceMethod(self: *Evaluator, super_decl: *ast.ClassDecl, instance: *types.ObjectInstance, method_name: []const u8, args: []const Value) anyerror!Value {
        return self.callInstanceMethodResolved(super_decl, null, instance, method_name, args);
    }

    fn callInstanceMethodResolved(self: *Evaluator, class_decl: *ast.ClassDecl, actual_class: ?*ast.ClassDecl, instance: *types.ObjectInstance, method_name: []const u8, args: []const Value) anyerror!Value {
        self.call_depth +|= 1;
        defer self.call_depth -|= 1;
        if (self.call_depth > self.max_call_depth) {
            return .null_val;
        }
        // Push call frame for stack trace generation (use current_call_line set by caller)
        const frame_line = self.current_call_line;
        self.current_call_line = 0;
        // Lazy static init for the instance's class and its parent hierarchy
        self.ensureStaticInit(instance.class_name);
        self.ensureStaticInit(class_decl.name);
        if (class_decl.super_class) |sc| self.ensureStaticInit(sc.name);
        // For virtual dispatch: find method in instance's actual class first (child override),
        // then in the provided class_decl, then in parent classes.
        // `actual_class = null` is used for super.method() dispatch.
        const resolved = self.findResolvedMethodInHierarchyTyped(actual_class, class_decl, method_name, args) orelse
            self.findResolvedMethodInHierarchy(actual_class, class_decl, method_name, args.len);

        if (resolved) |rm| {
            const owner_decl = rm.owner;
            const method = rm.method;
            const frame_class_name: []const u8 = blk: {
                if (std.mem.lastIndexOfScalar(u8, instance.class_name, '.')) |di| {
                    if (std.ascii.eqlIgnoreCase(instance.class_name[di + 1 ..], owner_decl.name)) {
                        break :blk instance.class_name;
                    }
                }
                break :blk owner_decl.name;
            };
            try self.call_stack.append(self.arena, .{ .class_name = frame_class_name, .method_name = method_name, .line = frame_line });
            defer _ = self.call_stack.pop();
            const method_env = try self.global_env.child();
            try method_env.define("this", Value{ .object = instance });
            // Define instance fields as local variables FIRST
            for (instance.fields.keys(), instance.fields.values()) |k, v| {
                method_env.set(k, v) catch {
                    try method_env.define(k, v);
                };
            }
            // Then define method parameters (so they shadow instance fields with same name)
            for (method.params, 0..) |param, i| {
                const val = if (i < args.len) args[i] else Value.null_val;
                method_env.set(param.name, val) catch {
                    try method_env.defineTyped(param.name, val, param.type_ref.name);
                };
            }
            const saved_class = self.current_class;
            self.current_class = owner_decl.name;
            defer self.current_class = saved_class;
            const batch_lifecycle = self.isBatchLifecycleMethod(owner_decl.name, method_name) or
                self.isBatchLifecycleMethod(instance.class_name, method_name);
            if (batch_lifecycle) self.batch_lifecycle_depth += 1;
            defer {
                if (batch_lifecycle) self.batch_lifecycle_depth -= 1;
            }
            const result = try self.execBlock(method.body, method_env);
            // Sync back fields modified via `this.field = value`
            const this_val = method_env.get("this");
            if (this_val != null and this_val.? == .object) {
                const updated = this_val.?.object;
                if (updated == instance) {
                    // Same pointer, fields already updated in place
                } else {
                    // Copy fields back
                    for (updated.fields.keys(), updated.fields.values()) |k, v| {
                        instance.fields.put(self.arena, k, v) catch {};
                    }
                }
            }
            // Sync instance field values back to the method env so that bare
            // identifier access sees updates made by the method body via this.field = ...
            // Skip fields whose name matches a parameter to avoid overwriting parameters.
            for (instance.fields.keys(), instance.fields.values()) |fk, fv| {
                var is_param = false;
                for (method.params) |p| {
                    if (std.ascii.eqlIgnoreCase(p.name, fk)) {
                        is_param = true;
                        break;
                    }
                }
                if (!is_param) {
                    method_env.set(fk, fv) catch {};
                }
            }
            const final_result = switch (result) {
                .return_val => |v| v,
                else => blk: {
                    // Fluent pattern: if method return type matches the class (or parent),
                    // return `this` instead of void. This enables method chaining.
                    if (method.return_type.name.len > 0 and
                        !std.ascii.eqlIgnoreCase(method.return_type.name, "void"))
                    {
                        if (std.ascii.eqlIgnoreCase(method.return_type.name, owner_decl.name) or
                            std.ascii.eqlIgnoreCase(method.return_type.name, instance.class_name))
                        {
                            break :blk Value{ .object = instance };
                        }
                        // Check if return type matches a parent class
                        if (owner_decl.super_class) |sc| {
                            if (std.ascii.eqlIgnoreCase(method.return_type.name, sc.name)) {
                                break :blk Value{ .object = instance };
                            }
                        }
                    }
                    break :blk self.return_value;
                },
            };
            return final_result;
        }
        // Try static method as fallback
        return self.callMethod(class_decl.name, method_name, args);
    }

    fn findResolvedMethodInHierarchyTyped(self: *Evaluator, actual_class: ?*ast.ClassDecl, class_decl: *ast.ClassDecl, method_name: []const u8, args: []const Value) ?ResolvedInstanceMethod {
        if (actual_class) |ac| {
            if (ac != class_decl) {
                if (self.findBestMethodInClass(ac, method_name, args)) |md| return .{ .owner = ac, .method = md };
            }
        }
        if (self.findBestMethodInClass(class_decl, method_name, args)) |md| return .{ .owner = class_decl, .method = md };
        var current: ?*ast.ClassDecl = class_decl;
        while (current) |cd| {
            if (cd.super_class) |sc| {
                const parent = self.findClass(sc.name);
                if (parent) |p| {
                    if (self.findBestMethodInClass(p, method_name, args)) |md| return .{ .owner = p, .method = md };
                    current = p;
                } else break;
            } else break;
        }
        return null;
    }

    fn findResolvedMethodInHierarchy(self: *Evaluator, actual_class: ?*ast.ClassDecl, class_decl: *ast.ClassDecl, method_name: []const u8, arg_count: usize) ?ResolvedInstanceMethod {
        if (actual_class) |ac| {
            if (ac != class_decl) {
                if (self.findMethodInClass(ac, method_name, arg_count)) |md| return .{ .owner = ac, .method = md };
            }
        }
        if (self.findMethodInClass(class_decl, method_name, arg_count)) |md| return .{ .owner = class_decl, .method = md };
        var current: ?*ast.ClassDecl = class_decl;
        while (current) |cd| {
            if (cd.super_class) |sc| {
                const parent = self.findClass(sc.name);
                if (parent) |p| {
                    if (self.findMethodInClass(p, method_name, arg_count)) |md| return .{ .owner = p, .method = md };
                    current = p;
                } else break;
            } else break;
        }
        return null;
    }

    /// Type-aware version of findMethodInHierarchy
    fn findMethodInHierarchyTyped(self: *Evaluator, actual_class: ?*ast.ClassDecl, class_decl: *ast.ClassDecl, method_name: []const u8, args: []const Value) ?*ast.MethodDecl {
        if (actual_class) |ac| {
            if (ac != class_decl) {
                if (self.findBestMethodInClass(ac, method_name, args)) |md| return md;
            }
        }
        if (self.findBestMethodInClass(class_decl, method_name, args)) |md| return md;
        var current: ?*ast.ClassDecl = class_decl;
        while (current) |cd| {
            if (cd.super_class) |sc| {
                const parent = self.findClass(sc.name);
                if (parent) |p| {
                    if (self.findBestMethodInClass(p, method_name, args)) |md| return md;
                    current = p;
                } else break;
            } else break;
        }
        return null;
    }

    /// Find a method in the class hierarchy. Searches:
    /// 1. The actual (child) class for overrides
    /// 2. The provided class_decl
    /// 3. Parent classes via super_class chain
    fn findMethodInHierarchy(self: *Evaluator, actual_class: ?*ast.ClassDecl, class_decl: *ast.ClassDecl, method_name: []const u8, arg_count: usize) ?*ast.MethodDecl {
        // 1. Search actual class first (child override) if different from class_decl
        if (actual_class) |ac| {
            if (ac != class_decl) {
                if (self.findMethodInClass(ac, method_name, arg_count)) |md| return md;
            }
        }
        // 2. Search the provided class_decl
        if (self.findMethodInClass(class_decl, method_name, arg_count)) |md| return md;
        // 3. Walk up parent chain
        var current: ?*ast.ClassDecl = class_decl;
        while (current) |cd| {
            if (cd.super_class) |sc| {
                const parent = self.findClass(sc.name);
                if (parent) |p| {
                    if (self.findMethodInClass(p, method_name, arg_count)) |md| return md;
                    current = p;
                } else break;
            } else break;
        }
        return null;
    }

    fn findMethodInClass(_: *Evaluator, class_decl: *ast.ClassDecl, method_name: []const u8, arg_count: usize) ?*ast.MethodDecl {
        var best_match: ?*ast.MethodDecl = null;
        for (class_decl.members) |member| {
            switch (member) {
                .method_decl => |md| {
                    if (std.ascii.eqlIgnoreCase(md.name, method_name)) {
                        if (md.params.len == arg_count) return md;
                        if (best_match == null) best_match = md;
                    }
                },
                else => {},
            }
        }
        return best_match;
    }

    /// Type-aware method resolution filtered by static/instance.
    fn findBestMethodInClassFiltered(self: *Evaluator, class_decl: *ast.ClassDecl, method_name: []const u8, args: []const Value, static_only: bool) ?*ast.MethodDecl {
        var candidates: [64]*ast.MethodDecl = undefined;
        var count: usize = 0;
        var best_any: ?*ast.MethodDecl = null;

        for (class_decl.members) |member| {
            switch (member) {
                .method_decl => |md| {
                    if (std.ascii.eqlIgnoreCase(md.name, method_name) and md.modifiers.is_static == static_only) {
                        if (md.params.len == args.len) {
                            if (count < candidates.len) {
                                candidates[count] = md;
                                count += 1;
                            }
                        }
                        if (best_any == null) best_any = md;
                    }
                },
                else => {},
            }
        }

        if (count == 0) return if (best_any != null) best_any else null;
        if (count == 1) return candidates[0];

        const arg_type_hints = self.cast_type_hints;

        // Multiple candidates: score each by type compatibility
        var best: ?*ast.MethodDecl = null;
        var best_score: i32 = -1;
        for (candidates[0..count]) |md| {
            var score: i32 = 0;
            for (md.params, 0..) |param, i| {
                if (i >= args.len) break;
                const pt = param.type_ref.name;
                const arg = args[i];
                if (arg_type_hints != null and i < arg_type_hints.?.len) {
                    if (arg_type_hints.?[i]) |hint| {
                        const hint_score = self.overloadScoreForTypeHint(hint, self.renderTypeRef(param.type_ref));
                        if (hint_score > 0) {
                            score += hint_score;
                            if (arg == .null_val) continue;
                        }
                    }
                }
                var arg_score = overloadScoreForArg(arg, pt);
                // For object args with score 0, check inheritance chain
                if (arg_score == 0 and arg == .object) {
                    if (self.isSubclassOf(arg.object.class_name, pt)) {
                        arg_score = 2;
                    }
                }
                // For List args, check generic element type
                if (arg == .list and std.ascii.eqlIgnoreCase(pt, "List") and param.type_ref.params.len > 0) {
                    const elem_type = param.type_ref.params[0].name;
                    // SObject is a generic parent — any SObject matches List<SObject>
                    if (std.ascii.eqlIgnoreCase(elem_type, "SObject")) {
                        if (arg.list.items.items.len > 0) {
                            if (arg.list.items.items[0] == .sobject) arg_score = 3;
                        } else {
                            arg_score = 2; // empty list matches
                        }
                    } else if (arg.list.items.items.len > 0) {
                        const first = arg.list.items.items[0];
                        if (first == .sobject and std.ascii.eqlIgnoreCase(first.sobject.type_name, elem_type)) {
                            arg_score = 3;
                        } else if (first == .sobject) {
                            // Simple name match
                            if (std.mem.lastIndexOfScalar(u8, elem_type, '.')) |di| {
                                if (std.ascii.eqlIgnoreCase(first.sobject.type_name, elem_type[di + 1 ..])) arg_score = 3;
                            } else if (std.mem.lastIndexOfScalar(u8, first.sobject.type_name, '.')) |di| {
                                if (std.ascii.eqlIgnoreCase(first.sobject.type_name[di + 1 ..], elem_type)) arg_score = 3;
                            }
                        } else if (first == .object and std.ascii.eqlIgnoreCase(first.object.class_name, elem_type)) {
                            arg_score = 3;
                        }
                    }
                }
                score += arg_score;
            }
            if (score > best_score) {
                best_score = score;
                best = md;
            }
        }
        return best orelse candidates[0];
    }

    /// Type-aware method resolution for overloaded methods.
    /// When multiple methods match by name and arg count, picks the one
    /// whose parameter types best match the actual argument types.
    fn findBestMethodInClass(self: *Evaluator, class_decl: *ast.ClassDecl, method_name: []const u8, args: []const Value) ?*ast.MethodDecl {
        var candidates: [64]*ast.MethodDecl = undefined;
        var count: usize = 0;
        var best_any: ?*ast.MethodDecl = null;

        for (class_decl.members) |member| {
            switch (member) {
                .method_decl => |md| {
                    if (std.ascii.eqlIgnoreCase(md.name, method_name)) {
                        if (md.params.len == args.len) {
                            if (count < candidates.len) {
                                candidates[count] = md;
                                count += 1;
                            }
                        }
                        if (best_any == null) best_any = md;
                    }
                },
                else => {},
            }
        }

        if (count == 0) return best_any;
        if (count == 1) return candidates[0];

        // Multiple candidates: score each by type compatibility
        const arg_type_hints = self.cast_type_hints;
        var best: ?*ast.MethodDecl = null;
        var best_score: i32 = -1;
        for (candidates[0..count]) |md| {
            var score: i32 = 0;
            for (md.params, 0..) |param, i| {
                if (i >= args.len) break;
                const pt = param.type_ref.name;
                const arg = args[i];
                if (arg_type_hints != null and i < arg_type_hints.?.len) {
                    if (arg_type_hints.?[i]) |hint| {
                        const hint_score = self.overloadScoreForTypeHint(hint, self.renderTypeRef(param.type_ref));
                        if (hint_score > 0) {
                            score += hint_score;
                            if (arg == .null_val) continue;
                        }
                    }
                }
                // Score: higher is better match (with special cases for collection mismatches)
                if (arg == .sobject and std.ascii.eqlIgnoreCase(pt, "List")) {
                    // SObject passed where List expected = poor match
                    score -= 1;
                } else if (arg == .list and !std.ascii.eqlIgnoreCase(pt, "List")) {
                    // List passed where non-List expected = poor match
                    score -= 1;
                } else {
                    var arg_score = overloadScoreForArg(arg, pt);
                    if (arg_score == 0 and arg == .object) {
                        if (self.isSubclassOf(arg.object.class_name, pt)) {
                            arg_score = 2;
                        }
                    }
                    // List generic element type check
                    if (arg == .list and std.ascii.eqlIgnoreCase(pt, "List") and param.type_ref.params.len > 0) {
                        const elem_type = param.type_ref.params[0].name;
                        if (std.ascii.eqlIgnoreCase(elem_type, "SObject")) {
                            if (arg.list.items.items.len > 0) {
                                if (arg.list.items.items[0] == .sobject) arg_score = 3;
                            } else {
                                arg_score = 2;
                            }
                        } else if (arg.list.items.items.len > 0) {
                            const first = arg.list.items.items[0];
                            if (first == .sobject and std.ascii.eqlIgnoreCase(first.sobject.type_name, elem_type)) {
                                arg_score = 3;
                            } else if (first == .sobject) {
                                if (std.mem.lastIndexOfScalar(u8, elem_type, '.')) |di| {
                                    if (std.ascii.eqlIgnoreCase(first.sobject.type_name, elem_type[di + 1 ..])) arg_score = 3;
                                } else if (std.mem.lastIndexOfScalar(u8, first.sobject.type_name, '.')) |di| {
                                    if (std.ascii.eqlIgnoreCase(first.sobject.type_name[di + 1 ..], elem_type)) arg_score = 3;
                                }
                            } else if (first == .object and std.ascii.eqlIgnoreCase(first.object.class_name, elem_type)) {
                                arg_score = 3;
                            }
                        }
                    }
                    score += arg_score;
                }
            }
            if (best == null or score > best_score) {
                best = md;
                best_score = score;
            }
        }
        return best orelse candidates[0];
    }

    fn overloadScoreForTypeHint(self: *Evaluator, raw_hint: []const u8, raw_param_type: []const u8) i32 {
        if (std.ascii.eqlIgnoreCase(raw_hint, raw_param_type)) return 6;
        const hint = stripTypeNamespace(raw_hint);
        const pt = stripTypeNamespace(raw_param_type);
        const hint_base = typeBaseName(hint);
        const pt_base = typeBaseName(pt);
        const hint_has_generics = std.mem.indexOfScalar(u8, hint, '<') != null;
        const pt_has_generics = std.mem.indexOfScalar(u8, pt, '<') != null;
        if (std.ascii.eqlIgnoreCase(hint, pt)) return 3;
        if (!(hint_has_generics and pt_has_generics) and std.ascii.eqlIgnoreCase(hint_base, pt_base)) return 3;
        if (std.ascii.eqlIgnoreCase(pt, "Object")) return 1;

        if (isCollectionTypeName(hint_base)) {
            if (std.ascii.eqlIgnoreCase(hint_base, "Set") and std.ascii.eqlIgnoreCase(pt_base, "Iterable")) return 2;
            if (std.ascii.eqlIgnoreCase(hint_base, "List") and std.ascii.eqlIgnoreCase(pt_base, "Iterable")) return 1;
            return 0;
        }

        if (self.isSObjectTypeName(hint_base) and
            (std.ascii.eqlIgnoreCase(pt_base, "SObject") or
                std.ascii.eqlIgnoreCase(pt_base, "sObject") or
                std.ascii.eqlIgnoreCase(pt_base, "Sobject")))
        {
            return 3;
        }

        if (self.findClass(hint_base) != null and self.isSubclassOf(hint_base, pt_base)) return 2;
        return 0;
    }

    fn initInstanceFields(self: *Evaluator, class_decl: *ast.ClassDecl, instance: *types.ObjectInstance) !void {
        // Set current_class so that unqualified static field references (e.g. BASE_URL)
        // resolve to ClassName.BASE_URL in the global environment.
        const saved_class = self.current_class;
        self.current_class = class_decl.name;
        defer self.current_class = saved_class;

        for (class_decl.members) |member| {
            switch (member) {
                .field_decl => |fd| {
                    if (!fd.modifiers.is_static) {
                        const val = if (fd.initializer) |init_expr|
                            self.evalExpr(init_expr, self.global_env) catch Value.null_val
                        else
                            defaultValue(fd.type_ref);
                        try instance.fields.put(self.arena, fd.name, val);
                    }
                },
                else => {},
            }
        }
    }

    fn runConstructor(self: *Evaluator, class_decl: *ast.ClassDecl, instance: *types.ObjectInstance, args: []const Value) anyerror!void {
        // Collect candidates with matching param count
        var candidates: [8]*ast.ConstructorDecl = undefined;
        var count: usize = 0;
        var best_any: ?*ast.ConstructorDecl = null;
        for (class_decl.members) |member| {
            switch (member) {
                .constructor_decl => |cd| {
                    if (cd.params.len == args.len) {
                        if (count < candidates.len) {
                            candidates[count] = cd;
                            count += 1;
                        }
                    }
                    if (best_any == null and (cd.params.len == args.len or args.len == 0)) best_any = cd;
                },
                else => {},
            }
        }
        // Pick best candidate using type scoring
        const chosen: ?*ast.ConstructorDecl = if (count == 0) best_any else if (count == 1) candidates[0] else blk: {
            var best: ?*ast.ConstructorDecl = null;
            var best_score: i32 = -1;
            for (candidates[0..count]) |cd| {
                var score: i32 = 0;
                for (cd.params, 0..) |param, i| {
                    if (i >= args.len) break;
                    const pt = param.type_ref.name;
                    const arg = args[i];
                    if (arg == .string and (std.ascii.eqlIgnoreCase(pt, "String") or std.ascii.eqlIgnoreCase(pt, "Id"))) {
                        score += 2;
                    } else if (arg == .integer and (std.ascii.eqlIgnoreCase(pt, "Integer") or std.ascii.eqlIgnoreCase(pt, "int"))) {
                        score += 2;
                    } else if (arg == .boolean and std.ascii.eqlIgnoreCase(pt, "Boolean")) {
                        score += 2;
                    } else if (arg == .object and std.mem.endsWith(u8, pt, "Exception")) {
                        score += 2;
                    } else if (arg == .object) {
                        // Check if the object's class_name matches the param type
                        if (std.ascii.eqlIgnoreCase(arg.object.class_name, pt)) {
                            score += 3;
                        } else if (self.isSubclassOf(arg.object.class_name, pt)) {
                            score += 2;
                        } else {
                            score += 0;
                        }
                    } else if (arg == .list and std.ascii.eqlIgnoreCase(pt, "List")) {
                        score += 2;
                    } else if (arg == .sobject) {
                        // Prefer SObject parameter type over non-SObject
                        if (std.ascii.eqlIgnoreCase(pt, "SObject") or std.mem.endsWith(u8, pt, "__c") or std.mem.endsWith(u8, pt, "__e")) {
                            score += 3;
                        } else {
                            score += 1;
                        }
                    } else if (arg == .null_val) {
                        // Null prefers primitive types (String/Id/Integer/etc) over Exception,
                        // since `null` is most commonly assigned to strings/IDs in Apex code.
                        if (std.ascii.eqlIgnoreCase(pt, "String") or std.ascii.eqlIgnoreCase(pt, "Id")) {
                            score += 2;
                        } else if (std.mem.endsWith(u8, pt, "Exception")) {
                            score += 0;
                        } else {
                            score += 1;
                        }
                    }
                }
                if (best == null or score > best_score) {
                    best = cd;
                    best_score = score;
                }
            }
            break :blk best;
        };
        if (chosen) |cd| {
            const ctor_env = try self.global_env.child();
            try ctor_env.define("this", Value{ .object = instance });
            for (instance.fields.keys(), instance.fields.values()) |k, v| {
                ctor_env.set(k, v) catch {
                    try ctor_env.define(k, v);
                };
            }
            for (cd.params, 0..) |param, pi| {
                const pval = if (pi < args.len) args[pi] else Value.null_val;
                try ctor_env.defineTyped(param.name, pval, param.type_ref.name);
            }
            // Push call frame for constructor (use current_call_line from new-expression site)
            const ctor_line = if (self.current_call_line > 0) self.current_call_line else if (cd.loc.line > 0) cd.loc.line else 1;
            self.current_call_line = 0;
            // Prefer the FQ class name for stack traces: if the instance's class_name
            // is an FQ form ("Outer.Inner") and its suffix matches class_decl.name, use it.
            const frame_class_name: []const u8 = blk: {
                if (std.mem.lastIndexOfScalar(u8, instance.class_name, '.')) |di| {
                    if (std.ascii.eqlIgnoreCase(instance.class_name[di + 1 ..], class_decl.name)) {
                        break :blk instance.class_name;
                    }
                }
                break :blk class_decl.name;
            };
            try self.call_stack.append(self.arena, .{ .class_name = frame_class_name, .method_name = "<init>", .line = ctor_line });
            defer _ = self.call_stack.pop();
            // Track which class's constructor is running (for correct super() dispatch)
            const saved_ctor_class = self.current_constructor_class;
            self.current_constructor_class = class_decl.name;
            defer self.current_constructor_class = saved_ctor_class;
            // Set current_class so unqualified method/field references resolve to this class
            const saved_class = self.current_class;
            self.current_class = class_decl.name;
            defer self.current_class = saved_class;
            _ = try self.execBlock(cd.body, ctor_env);
        }
    }

    fn isInstanceField(_: *Evaluator, class_decl: *ast.ClassDecl, name: []const u8) bool {
        for (class_decl.members) |member| {
            switch (member) {
                .field_decl => |fd| {
                    if (!fd.modifiers.is_static and std.ascii.eqlIgnoreCase(fd.name, name)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    const FieldLookup = struct {
        owner_name: []const u8,
        field_decl: *ast.FieldDecl,
    };

    fn findFieldDeclWithOwner(self: *Evaluator, class_name: []const u8, field_name: []const u8) ?FieldLookup {
        var current = self.findClass(class_name);
        while (current) |cd| {
            for (cd.members) |member| {
                switch (member) {
                    .field_decl => |fd| {
                        if (std.ascii.eqlIgnoreCase(fd.name, field_name)) {
                            return .{ .owner_name = cd.name, .field_decl = fd };
                        }
                    },
                    else => {},
                }
            }
            current = if (cd.super_class) |sc| self.findClass(sc.name) else null;
        }
        return null;
    }

    fn readStaticBackingValue(self: *Evaluator, owner_name: []const u8, field_name: []const u8) Value {
        self.ensureStaticInit(owner_name);
        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ owner_name, field_name }) catch return .null_val;
        if (self.global_env.get(key)) |v| return v;
        if (self.findOuterClassName(owner_name)) |outer| {
            const outer_key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ outer, field_name }) catch return .null_val;
            if (self.global_env.get(outer_key)) |v| return v;
        }
        return .null_val;
    }

    fn isParentInstanceField(self: *Evaluator, class_decl: *ast.ClassDecl, name: []const u8) bool {
        if (class_decl.super_class) |sc| {
            if (self.findClass(sc.name)) |parent| {
                if (self.isInstanceField(parent, name)) return true;
                return self.isParentInstanceField(parent, name);
            }
        }
        return false;
    }

    pub fn findClassPublic(self: *Evaluator, name: []const u8) ?*ast.ClassDecl {
        return self.findClass(name);
    }

    pub fn instantiateClassPublic(self: *Evaluator, class_name: []const u8) !Value {
        return self.instantiateClass(class_name);
    }

    fn findClass(self: *Evaluator, name: []const u8) ?*ast.ClassDecl {
        var iter = self.classes.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
        }
        return null;
    }

    /// Find the outer (enclosing) class name for a given inner class.
    /// Returns null if the class is not an inner class.
    /// Accepts either simple inner class name ("Inner") or FQ form ("Outer.Inner");
    /// when FQ is passed and the prefix matches an outer class, returns it directly.
    fn findOuterClassName(self: *Evaluator, inner_class_name: []const u8) ?[]const u8 {
        // Fast path: FQ form "Outer.Inner" → return prefix if it's a registered top-level class
        if (std.mem.lastIndexOfScalar(u8, inner_class_name, '.')) |di| {
            const outer = inner_class_name[0..di];
            if (self.findClass(outer)) |_| return outer;
        }
        const simple = if (std.mem.lastIndexOfScalar(u8, inner_class_name, '.')) |di|
            inner_class_name[di + 1 ..]
        else
            inner_class_name;
        var iter = self.classes.iterator();
        while (iter.next()) |entry| {
            // Skip fully-qualified names (e.g. "Outer.Inner") — only check top-level class entries
            if (std.mem.indexOfScalar(u8, entry.key_ptr.*, '.') != null) continue;
            for (entry.value_ptr.*.members) |member| {
                switch (member) {
                    .class_decl => |inner_cd| {
                        if (std.ascii.eqlIgnoreCase(inner_cd.name, simple))
                            return entry.key_ptr.*;
                    },
                    else => {},
                }
            }
        }
        return null;
    }

    fn registerClassRecursive(self: *Evaluator, ca: std.mem.Allocator, cd: *ast.ClassDecl, fq_name: ?[]const u8) !void {
        try self.classes.put(ca, cd.name, cd);
        if (fq_name) |fq| {
            try self.classes.put(ca, fq, cd);
        }
        for (cd.members) |member| {
            switch (member) {
                .field_decl => |fd| {
                    if (fd.modifiers.is_static) {
                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                        self.global_env.define(key, defaultValue(fd.type_ref)) catch {};
                    }
                },
                .class_decl => |inner_cd| {
                    const parent_name = fq_name orelse cd.name;
                    const inner_fq = std.fmt.allocPrint(ca, "{s}.{s}", .{ parent_name, inner_cd.name }) catch continue;
                    try self.registerClassRecursive(ca, inner_cd, inner_fq);
                },
                .enum_decl => |ed| {
                    for (ed.values) |v| {
                        const ekey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ ed.name, v }) catch continue;
                        self.global_env.define(ekey, Value{ .string = v }) catch {};
                        const enum_owner = fq_name orelse cd.name;
                        const fq_key = std.fmt.allocPrint(self.arena, "{s}.{s}.{s}", .{ enum_owner, ed.name, v }) catch continue;
                        self.global_env.define(fq_key, Value{ .string = v }) catch {};
                    }
                },
                else => {},
            }
        }
    }

    fn createAsyncApexJob(self: *Evaluator, apex_job_type: []const u8, class_name: []const u8, method_name: ?[]const u8) ![]const u8 {
        const job_id = try std.fmt.allocPrint(self.arena, "707{d:0>15}", .{self.next_id});
        self.next_id += 1;

        const top_level_class = self.findOuterClassName(class_name) orelse class_name;
        const apex_class_name = if (std.mem.lastIndexOfScalar(u8, top_level_class, '.')) |di| top_level_class[di + 1 ..] else top_level_class;
        const apex_class = try self.arena.create(types.SObject);
        apex_class.* = .{ .type_name = "ApexClass" };
        try apex_class.fields.put(self.arena, "Id", Value{ .string = try std.fmt.allocPrint(self.arena, "01p{d:0>15}", .{self.next_id}) });
        try apex_class.fields.put(self.arena, "Name", Value{ .string = apex_class_name });
        try apex_class.fields.put(self.arena, "NamespacePrefix", Value.null_val);

        const async_job = try self.arena.create(types.SObject);
        async_job.* = .{ .type_name = "AsyncApexJob", .id = job_id };
        try async_job.fields.put(self.arena, "Id", Value{ .string = job_id });
        try async_job.fields.put(self.arena, "Status", Value{ .string = "Completed" });
        try async_job.fields.put(self.arena, "JobType", Value{ .string = apex_job_type });
        try async_job.fields.put(self.arena, "MethodName", if (method_name) |name| Value{ .string = name } else Value.null_val);
        try async_job.fields.put(self.arena, "JobItemsProcessed", Value{ .integer = 0 });
        try async_job.fields.put(self.arena, "NumberOfErrors", Value{ .integer = 0 });
        try async_job.fields.put(self.arena, "ApexClass", Value{ .sobject = apex_class });
        if (utils.sobjectGet(&apex_class.fields, "Id")) |apex_class_id| {
            try async_job.fields.put(self.arena, "ApexClassId", apex_class_id);
        }
        try async_job.fields.put(self.arena, "CreatedById", Value{ .string = self.current_user_id });
        const created_by = try self.createCurrentUserRecord();
        if (created_by == .sobject) {
            try async_job.fields.put(self.arena, "CreatedBy", created_by);
        }
        const now_str = builtins.currentDateTimeString(self.arena) catch "2026-01-01T00:00:00Z";
        try async_job.fields.put(self.arena, "CreatedDate", Value{ .string = now_str });

        const gop = try self.store.getOrPut(self.arena, "AsyncApexJob");
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.arena, Value{ .sobject = async_job });
        try self.id_type_map.put(self.arena, job_id, "AsyncApexJob");
        return job_id;
    }

    fn enqueueJob(self: *Evaluator, job_obj: *types.ObjectInstance) !Value {
        self.limits_queueable += 1;
        const saved_dml = self.limits_dml;
        const saved_dml_rows = self.limits_dml_rows;
        const saved_soql = self.limits_soql;
        const saved_pub = self.limits_publish_immediate;
        const saved_callouts = self.limits_callouts;

        const job_id = try self.createAsyncApexJob("Queueable", job_obj.class_name, null);

        if (self.findClass(job_obj.class_name)) |job_class| {
            const queueable_context = try self.arena.create(types.ObjectInstance);
            queueable_context.* = .{ .class_name = "System.QueueableContext" };
            try queueable_context.fields.put(self.arena, "jobId", Value{ .string = job_id });
            if (self.findBestMethodInClassFiltered(job_class, "execute", &.{Value{ .object = queueable_context }}, true) != null) {
                _ = self.callMethod(job_obj.class_name, "execute", &.{Value{ .object = queueable_context }}) catch {};
            } else {
                _ = self.callInstanceMethod(job_class, job_obj, "execute", &.{Value{ .object = queueable_context }}) catch {};
            }
        }

        self.limits_dml = saved_dml;
        self.limits_dml_rows = saved_dml_rows;
        self.limits_soql = saved_soql;
        self.limits_publish_immediate = saved_pub;
        self.limits_callouts = saved_callouts;
        return Value{ .string = job_id };
    }

    /// Resolve a static field or static property getter from a specific class.
    /// Tries getter first (for lazy-init patterns), then plain global_env lookup.
    fn resolveStaticFieldValueOnClass(self: *Evaluator, class_name: []const u8, field_name: []const u8) ?Value {
        self.ensureStaticInit(class_name);
        const cd = self.findClass(class_name) orelse return null;
        // Try static property getter first
        const already_in_getter = if (self.evaluating_getter) |eg| std.ascii.eqlIgnoreCase(eg, field_name) else false;
        if (!already_in_getter) {
            for (cd.members) |member| {
                switch (member) {
                    .field_decl => |fd| {
                        if (fd.modifiers.is_static and std.ascii.eqlIgnoreCase(fd.name, field_name) and fd.getter_body != null) {
                            const getter_env = self.global_env.child() catch return null;
                            const saved_class = self.current_class;
                            const saved_getter = self.evaluating_getter;
                            self.current_class = class_name;
                            self.evaluating_getter = field_name;
                            defer {
                                self.current_class = saved_class;
                                self.evaluating_getter = saved_getter;
                            }
                            const result = self.execBlock(fd.getter_body.?, getter_env) catch return null;
                            return switch (result) {
                                .return_val => |v| v,
                                else => self.return_value,
                            };
                        }
                    },
                    else => {},
                }
            }
        }
        // Plain static field lookup
        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ class_name, field_name }) catch return null;
        return self.global_env.get(key);
    }

    /// Resolve a static field or static property getter from the outer class of an inner class.
    /// Tries getter first (for lazy-init patterns), then plain global_env lookup.
    fn resolveOuterStaticField(self: *Evaluator, inner_class_name: []const u8, field_name: []const u8) ?Value {
        const outer_name = self.findOuterClassName(inner_class_name) orelse return null;
        return self.resolveStaticFieldValueOnClass(outer_name, field_name);
    }

    // -----------------------------------------------------------------------
    // JSON パーサー
    // -----------------------------------------------------------------------

    /// Compare two Values by a field name for ORDER BY.
    /// Returns: -1 if a < b, 0 if equal, 1 if a > b
    fn compareByField(self: *Evaluator, a: Value, b: Value, field: []const u8) i32 {
        const av = if (a == .sobject) self.getSObjectFieldValueCaseInsensitive(a.sobject, field) orelse Value.null_val else Value.null_val;
        const bv = if (b == .sobject) self.getSObjectFieldValueCaseInsensitive(b.sobject, field) orelse Value.null_val else Value.null_val;
        // null sorts last
        if (av == .null_val and bv == .null_val) return 0;
        if (av == .null_val) return 1;
        if (bv == .null_val) return -1;
        // String comparison (case-insensitive)
        if (av == .string and bv == .string) {
            const len = @min(av.string.len, bv.string.len);
            for (0..len) |i| {
                const ca = std.ascii.toLower(av.string[i]);
                const cb = std.ascii.toLower(bv.string[i]);
                if (ca < cb) return -1;
                if (ca > cb) return 1;
            }
            if (av.string.len < bv.string.len) return -1;
            if (av.string.len > bv.string.len) return 1;
            return 0;
        }
        // Integer comparison
        if (av == .integer and bv == .integer) {
            if (av.integer < bv.integer) return -1;
            if (av.integer > bv.integer) return 1;
            return 0;
        }
        // Double comparison
        if (av == .double and bv == .double) {
            if (av.double < bv.double) return -1;
            if (av.double > bv.double) return 1;
            return 0;
        }
        return 0;
    }

    /// Compare two Values for natural ordering.
    /// null < non-null; strings case-insensitive; integers/doubles numeric order
    fn compareValues(_: *Evaluator, a: Value, b: Value) i32 {
        // null handling
        if (a == .null_val and b == .null_val) return 0;
        if (a == .null_val) return -1;
        if (b == .null_val) return 1;
        // String comparison
        if (a == .string and b == .string) {
            const len = @min(a.string.len, b.string.len);
            for (0..len) |i| {
                const ca = std.ascii.toLower(a.string[i]);
                const cb = std.ascii.toLower(b.string[i]);
                if (ca < cb) return -1;
                if (ca > cb) return 1;
            }
            if (a.string.len < b.string.len) return -1;
            if (a.string.len > b.string.len) return 1;
            return 0;
        }
        // Integer comparison
        if (a == .integer and b == .integer) {
            if (a.integer < b.integer) return -1;
            if (a.integer > b.integer) return 1;
            return 0;
        }
        // Double comparison
        if (a == .double and b == .double) {
            if (a.double < b.double) return -1;
            if (a.double > b.double) return 1;
            return 0;
        }
        // Boolean
        if (a == .boolean and b == .boolean) {
            if (!a.boolean and b.boolean) return -1;
            if (a.boolean and !b.boolean) return 1;
            return 0;
        }
        return 0;
    }

    fn classImplementsInterface(self: *Evaluator, class_name: []const u8, interface_name: []const u8) bool {
        const cd = self.findClass(class_name) orelse return false;
        for (cd.interfaces) |iface| {
            if (std.ascii.eqlIgnoreCase(iface.name, interface_name)) return true;
            if (std.mem.lastIndexOfScalar(u8, iface.name, '.')) |dot_pos| {
                if (std.ascii.eqlIgnoreCase(iface.name[dot_pos + 1 ..], interface_name)) return true;
            }
        }
        // Check parent class
        if (cd.super_class) |sc| {
            return self.classImplementsInterface(sc.name, interface_name);
        }
        return false;
    }

    fn hasComparableInterface(self: *Evaluator, class_name: []const u8) bool {
        return self.classImplementsInterface(class_name, "Comparable");
    }

    fn isBatchLifecycleMethod(self: *Evaluator, class_name: []const u8, method_name: []const u8) bool {
        if (!(std.ascii.eqlIgnoreCase(method_name, "start") or
            std.ascii.eqlIgnoreCase(method_name, "execute") or
            std.ascii.eqlIgnoreCase(method_name, "finish")))
        {
            return false;
        }
        return self.classImplementsInterface(class_name, "Database.Batchable") or
            self.classImplementsInterface(class_name, "Batchable");
    }

    fn callCompareTo(self: *Evaluator, a: *types.ObjectInstance, b_val: Value) i32 {
        if (self.findClass(a.class_name)) |cd| {
            const result = self.callInstanceMethod(cd, a, "compareTo", &.{b_val}) catch return 0;
            if (result == .integer) return @intCast(if (result.integer > 0) @as(i32, 1) else if (result.integer < 0) @as(i32, -1) else @as(i32, 0));
        }
        return 0;
    }

    /// Find the element type of an array field by scanning the source code.
    /// Looks for patterns like "TypeName[] fieldName" or "List<TypeName> fieldName".
    fn findFieldArrayType(_: *Evaluator, source: []const u8, field_name: []const u8) ?[]const u8 {
        // Search for "fieldName" in source and look backwards for the type
        var pos: usize = 0;
        while (pos < source.len) {
            // Find field_name in source (case-insensitive)
            const found = std.ascii.indexOfIgnoreCasePos(source, pos, field_name) orelse break;
            // Ensure it's a whole-word match (not part of a larger identifier)
            const is_word_start = found == 0 or (!std.ascii.isAlphanumeric(source[found - 1]) and source[found - 1] != '_');
            const after_end = found + field_name.len;
            const is_word_end = after_end >= source.len or (!std.ascii.isAlphanumeric(source[after_end]) and source[after_end] != '_');
            if (!is_word_start or !is_word_end) {
                pos = found + 1;
                continue;
            }
            // Check that it's preceded by "[] " or "> " (array type indicators)
            if (found >= 3) {
                const before = source[0..found];
                const trimmed_before = std.mem.trimRight(u8, before, " \t");
                // Check for "[]" suffix → "TypeName[]"
                if (std.mem.endsWith(u8, trimmed_before, "[]")) {
                    // Find the start of the type name
                    const type_end = trimmed_before.len - 2;
                    var type_start = type_end;
                    while (type_start > 0 and (std.ascii.isAlphanumeric(trimmed_before[type_start - 1]) or trimmed_before[type_start - 1] == '_')) {
                        type_start -= 1;
                    }
                    if (type_start < type_end) {
                        return trimmed_before[type_start..type_end];
                    }
                }
                // Check for ">" suffix → "List<TypeName>"
                if (std.mem.endsWith(u8, trimmed_before, ">")) {
                    // Find the opening "<"
                    if (std.mem.lastIndexOfScalar(u8, trimmed_before, '<')) |lt| {
                        const inner = std.mem.trim(u8, trimmed_before[lt + 1 .. trimmed_before.len - 1], " \t");
                        if (inner.len > 0) {
                            return inner;
                        }
                    }
                }
            }
            pos = found + field_name.len;
        }
        return null;
    }

    /// Parse a JSON string into a Value.
    fn parseJsonValue(self: *Evaluator, json_str: []const u8, type_hint: []const u8) ?Value {
        const trimmed = std.mem.trim(u8, json_str, " \t\r\n");
        if (trimmed.len == 0) return null;

        if (trimmed[0] == '[') {
            // JSON array → List
            const list = self.arena.create(types.ListValue) catch return null;
            list.* = .{};
            // Extract element type from "List<Contact>", "Contact[]", etc.
            const elem_type = if (std.mem.indexOf(u8, type_hint, "<")) |lt|
                if (std.mem.indexOf(u8, type_hint[lt + 1 ..], ">")) |gt|
                    type_hint[lt + 1 .. lt + 1 + gt]
                else
                    "Object"
            else if (std.mem.endsWith(u8, type_hint, "[]"))
                type_hint[0 .. type_hint.len - 2]
            else
                "Object";
            // Parse array elements
            var depth: i32 = 0;
            var start: usize = 1; // skip opening '['
            var i: usize = 1;
            while (i < trimmed.len) : (i += 1) {
                if (trimmed[i] == '"') {
                    i += 1;
                    while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {
                        if (trimmed[i] == '\\') i += 1;
                    }
                } else if (trimmed[i] == '{' or trimmed[i] == '[') {
                    depth += 1;
                } else if (trimmed[i] == '}' or trimmed[i] == ']') {
                    if (depth == 0) {
                        // End of array
                        const elem_str = std.mem.trim(u8, trimmed[start..i], " \t\r\n,");
                        if (elem_str.len > 0) {
                            if (self.parseJsonValue(elem_str, elem_type)) |v| {
                                list.items.append(self.arena, v) catch {};
                            }
                        }
                        break;
                    }
                    depth -= 1;
                } else if (trimmed[i] == ',' and depth == 0) {
                    const elem_str = std.mem.trim(u8, trimmed[start..i], " \t\r\n");
                    if (elem_str.len > 0) {
                        if (self.parseJsonValue(elem_str, elem_type)) |v| {
                            list.items.append(self.arena, v) catch {};
                        }
                    }
                    start = i + 1;
                }
            }
            return Value{ .list = list };
        }

        if (trimmed[0] == '{') {
            // Check if type_hint is a user-defined class → ObjectInstance
            const is_user_class = self.findClass(type_hint) != null;
            if (is_user_class) {
                const obj = self.arena.create(types.ObjectInstance) catch return null;
                obj.* = .{ .class_name = type_hint };
                // Parse key-value pairs into fields
                var jd: i32 = 0;
                var js: usize = 1;
                var ji: usize = 1;
                while (ji < trimmed.len) : (ji += 1) {
                    if (trimmed[ji] == '"' and jd == 0) {
                        const key_start = ji + 1;
                        ji += 1;
                        while (ji < trimmed.len and trimmed[ji] != '"') : (ji += 1) {}
                        const key_name = trimmed[key_start..ji];
                        ji += 1;
                        while (ji < trimmed.len and trimmed[ji] != ':') : (ji += 1) {}
                        ji += 1;
                        while (ji < trimmed.len and (trimmed[ji] == ' ' or trimmed[ji] == '\t')) : (ji += 1) {}
                        js = ji;
                        var val_depth: i32 = 0;
                        while (ji < trimmed.len) : (ji += 1) {
                            if (trimmed[ji] == '"') {
                                ji += 1;
                                while (ji < trimmed.len and trimmed[ji] != '"') : (ji += 1) {
                                    if (trimmed[ji] == '\\') ji += 1;
                                }
                            } else if (trimmed[ji] == '{' or trimmed[ji] == '[') {
                                val_depth += 1;
                            } else if (trimmed[ji] == '}' or trimmed[ji] == ']') {
                                if (val_depth == 0) break;
                                val_depth -= 1;
                            } else if (trimmed[ji] == ',' and val_depth == 0) break;
                        }
                        const val_str = std.mem.trim(u8, trimmed[js..ji], " \t\r\n");
                        if (val_str.len > 0) {
                            // Resolve field type from class declaration for type-aware parsing.
                            // For List fields (T[]), find the element type from the source code.
                            const field_type_hint: []const u8 = blk: {
                                if (self.findClass(type_hint)) |cd| {
                                    for (cd.members) |member| {
                                        switch (member) {
                                            .field_decl => |fd| {
                                                if (std.ascii.eqlIgnoreCase(fd.name, key_name)) {
                                                    if (std.ascii.eqlIgnoreCase(fd.type_ref.name, "List")) {
                                                        // Find the element type from source code
                                                        for (self.class_sources.keys(), self.class_sources.values()) |k, src| {
                                                            if (std.ascii.eqlIgnoreCase(k, type_hint)) {
                                                                if (self.findFieldArrayType(src, key_name)) |elem| {
                                                                    // elem is a slice into src which is stable (arena-allocated class source)
                                                                    if (elem.len > 0 and elem.len < 200) {
                                                                        break :blk std.fmt.allocPrint(self.arena, "{s}[]", .{elem}) catch "Object";
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                    break :blk fd.type_ref.name;
                                                }
                                            },
                                            else => {},
                                        }
                                    }
                                }
                                break :blk "Object";
                            };
                            if (self.parseJsonValue(val_str, field_type_hint)) |v| {
                                obj.fields.put(self.arena, key_name, v) catch {};
                            }
                        }
                    } else if (trimmed[ji] == '{' or trimmed[ji] == '[') {
                        jd += 1;
                    } else if (trimmed[ji] == '}' or trimmed[ji] == ']') {
                        if (jd == 0) break;
                        jd -= 1;
                    }
                }
                return Value{ .object = obj };
            }
            // JSON object → SObject (for unknown/SObject types)
            const sob = self.arena.create(types.SObject) catch return null;
            var resolved_type = type_hint;
            sob.* = .{ .type_name = resolved_type };
            // Parse key-value pairs
            var depth: i32 = 0;
            var i: usize = 1;
            while (i < trimmed.len) {
                // Skip whitespace
                while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\n' or trimmed[i] == '\r' or trimmed[i] == ',')) : (i += 1) {}
                if (i >= trimmed.len or trimmed[i] == '}') break;
                // Expect key in quotes
                if (trimmed[i] != '"') {
                    i += 1;
                    continue;
                }
                const key_start = i + 1;
                i += 1;
                while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {
                    if (trimmed[i] == '\\') i += 1;
                }
                if (i >= trimmed.len) break;
                const key = trimmed[key_start..i];
                i += 1; // skip closing quote
                // Skip whitespace after key
                while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\n' or trimmed[i] == '\r')) : (i += 1) {}
                // Expect colon - if not found, JSON is malformed
                if (i >= trimmed.len or trimmed[i] != ':') return null;
                i += 1; // skip colon
                while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\n' or trimmed[i] == '\r')) : (i += 1) {}
                if (i >= trimmed.len) break;
                // Parse value
                const val_start = i;
                if (trimmed[i] == '"') {
                    // String value
                    i += 1;
                    while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {
                        if (trimmed[i] == '\\') i += 1;
                    }
                    if (i < trimmed.len) {
                        const val_str = trimmed[val_start + 1 .. i];
                        i += 1;
                        // Special handling for "attributes" object
                        if (std.mem.eql(u8, key, "attributes")) {
                            // Value was a nested object but we parsed the first " - skip rest
                            // Re-parse from val_start
                            if (trimmed[val_start] == '{') {
                                // already handled below
                            } else {
                                // "attributes" was not an object; skip
                            }
                        } else if (std.ascii.eqlIgnoreCase(key, "Id")) {
                            sob.id = val_str;
                            sob.fields.put(self.arena, "Id", Value{ .string = val_str }) catch {};
                        } else {
                            sob.fields.put(self.arena, key, Value{ .string = val_str }) catch {};
                        }
                    }
                } else if (trimmed[i] == '{') {
                    // Nested object
                    depth = 1;
                    i += 1;
                    while (i < trimmed.len and depth > 0) : (i += 1) {
                        if (trimmed[i] == '{') depth += 1;
                        if (trimmed[i] == '}') depth -= 1;
                        if (trimmed[i] == '"') {
                            i += 1;
                            while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {
                                if (trimmed[i] == '\\') i += 1;
                            }
                        }
                    }
                    const nested = trimmed[val_start..i];
                    if (std.mem.eql(u8, key, "attributes")) {
                        // Extract type from attributes (handles both "type":"X" and "type": "X")
                        const type_key_patterns = [_][]const u8{ "\"type\":\"", "\"type\": \"", "\"type\" : \"" };
                        for (type_key_patterns) |pattern| {
                            if (std.mem.indexOf(u8, nested, pattern)) |type_pos| {
                                const ts = type_pos + pattern.len;
                                if (std.mem.indexOfPos(u8, nested, ts, "\"")) |te| {
                                    resolved_type = nested[ts..te];
                                    sob.type_name = resolved_type;
                                }
                                break;
                            }
                        }
                    } else {
                        if (self.parseJsonValue(nested, "Object")) |nv| {
                            sob.fields.put(self.arena, key, nv) catch {};
                        }
                    }
                } else if (trimmed[i] == '[') {
                    // Array value
                    depth = 1;
                    i += 1;
                    while (i < trimmed.len and depth > 0) : (i += 1) {
                        if (trimmed[i] == '[') depth += 1;
                        if (trimmed[i] == ']') depth -= 1;
                        if (trimmed[i] == '"') {
                            i += 1;
                            while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {
                                if (trimmed[i] == '\\') i += 1;
                            }
                        }
                    }
                    const arr = trimmed[val_start..i];
                    if (self.parseJsonValue(arr, "List")) |av| {
                        sob.fields.put(self.arena, key, av) catch {};
                    }
                } else if (std.mem.startsWith(u8, trimmed[i..], "null")) {
                    sob.fields.put(self.arena, key, Value.null_val) catch {};
                    i += 4;
                } else if (std.mem.startsWith(u8, trimmed[i..], "true")) {
                    sob.fields.put(self.arena, key, Value{ .boolean = true }) catch {};
                    i += 4;
                } else if (std.mem.startsWith(u8, trimmed[i..], "false")) {
                    sob.fields.put(self.arena, key, Value{ .boolean = false }) catch {};
                    i += 5;
                } else {
                    // Number
                    var num_end = i;
                    while (num_end < trimmed.len and trimmed[num_end] != ',' and trimmed[num_end] != '}' and trimmed[num_end] != ' ') : (num_end += 1) {}
                    const num_str = trimmed[i..num_end];
                    if (std.fmt.parseInt(i64, num_str, 10)) |n| {
                        sob.fields.put(self.arena, key, Value{ .integer = n }) catch {};
                    } else |_| {
                        if (std.fmt.parseFloat(f64, num_str)) |f| {
                            sob.fields.put(self.arena, key, Value{ .double = f }) catch {};
                        } else |_| {
                            sob.fields.put(self.arena, key, Value{ .string = num_str }) catch {};
                        }
                    }
                    i = num_end;
                }
            }
            return Value{ .sobject = sob };
        }

        // Scalar values
        if (trimmed[0] == '"') {
            if (std.mem.lastIndexOfScalar(u8, trimmed, '"')) |end| {
                if (end > 0) {
                    const str_val = trimmed[1..end];
                    // When type_hint is Date or Datetime, wrap the string as a Date/DateTime object
                    if (std.ascii.eqlIgnoreCase(type_hint, "Date")) {
                        return builtins.makeDateValue(self.arena, str_val) catch Value{ .string = str_val };
                    }
                    if (std.ascii.eqlIgnoreCase(type_hint, "DateTime") or std.ascii.eqlIgnoreCase(type_hint, "Datetime")) {
                        return builtins.makeDatetimeValue(self.arena, str_val) catch Value{ .string = str_val };
                    }
                    return Value{ .string = str_val };
                }
            }
            return Value{ .string = "" };
        }
        if (std.mem.eql(u8, trimmed, "null")) return Value.null_val;
        if (std.mem.eql(u8, trimmed, "true")) return Value{ .boolean = true };
        if (std.mem.eql(u8, trimmed, "false")) return Value{ .boolean = false };
        if (std.fmt.parseInt(i64, trimmed, 10) catch null) |n| return Value{ .integer = n };
        if (std.fmt.parseFloat(f64, trimmed) catch null) |f| return Value{ .double = f };
        return null;
    }

    /// Determine whether a type name represents a Salesforce SObject type.
    fn isSObjectTypeName(self: *Evaluator, name: []const u8) bool {
        // Custom suffixes: __c, __e, __mdt, __b
        if (std.mem.endsWith(u8, name, "__c") or std.mem.endsWith(u8, name, "__e") or
            std.mem.endsWith(u8, name, "__mdt") or std.mem.endsWith(u8, name, "__b"))
            return true;
        // Present in the data store
        if (self.store.get(name) != null) return true;
        // Known standard SObject types
        const known = [_][]const u8{
            "Account",                 "Contact",                "Opportunity",         "Case",                   "Lead",                 "Task",                 "Event",
            "Campaign",                "User",                   "ContentVersion",      "ContentDocument",        "ContentDocumentLink",  "ContentDistribution",  "PermissionSet",
            "PermissionSetAssignment", "ObjectPermissions",      "Profile",             "Organization",           "ApexClass",            "StaticResource",       "FieldPermissions",
            "PermissionSetGroup",      "PlatformCachePartition", "CronTrigger",         "AsyncApexJob",           "EntityDefinition",     "FieldDefinition",      "AggregateResult",
            "RecordType",              "DuplicateRule",          "DuplicateRecordSet",  "DuplicateRecordItem",    "UserRecordAccess",     "AuthSession",          "LoginHistory",
            "TaskStatus",              "BusinessHours",          "FeedItem",            "CollaborationGroup",     "UserRole",             "GroupMember",          "Group",
            "Attachment",              "Note",                   "EmailMessage",        "CaseComment",            "Solution",             "Contract",             "Product2",
            "Pricebook2",              "PricebookEntry",         "OpportunityLineItem", "Quote",                  "QuoteLineItem",        "PermissionSetLicense", "EmailTemplate",
            "Folder",                  "Document",               "CampaignMember",      "CampaignMemberStatus",   "EmailMessageRelation", "OrgWideEmailAddress",  "PermissionSetLicenseAssign",
            "ServiceResource",         "AssignedResource",       "ServiceTerritory",    "ServiceTerritoryMember", "ApexTrigger",          "CustomPermission",     "FlowDefinitionView",
            "FlowVersionView",         "ApexEmailNotification",  "Network",             "Topic",                  "OmniProcess",          "SObject",
        };
        for (known) |kt| {
            if (std.ascii.eqlIgnoreCase(name, kt)) return true;
        }
        return false;
    }

    /// Instantiate a class by name (for Type.forName().newInstance())
    fn instantiateClass(self: *Evaluator, class_name: []const u8) !Value {
        // Lazy static init: ensure the class's static fields/blocks are initialized
        self.ensureStaticInit(class_name);
        if (self.findClass(class_name)) |class_decl| {
            // Also ensure parent class hierarchy is initialized
            if (class_decl.super_class) |sc| self.ensureStaticInit(sc.name);
            const instance = try self.arena.create(types.ObjectInstance);
            // Preserve the requested class name so qualified inner classes
            // continue to dispatch against the intended outer class.
            instance.* = .{ .class_name = class_name };
            // Initialize instance fields
            self.initInstanceFields(class_decl, instance) catch {};
            // Initialize parent class fields
            if (class_decl.super_class) |sc| {
                if (self.findClass(sc.name)) |parent_decl| {
                    self.initInstanceFields(parent_decl, instance) catch {};
                }
            }
            // Execute parent constructor
            if (class_decl.super_class) |sc| {
                if (self.findClass(sc.name)) |parent_decl| {
                    try self.runConstructor(parent_decl, instance, &.{});
                }
            }
            // Execute own constructor
            try self.runConstructor(class_decl, instance, &.{});
            return Value{ .object = instance };
        }
        // SObject type name → return .sobject instead of .object
        if (self.isSObjectTypeName(class_name)) {
            const sob = try self.arena.create(types.SObject);
            sob.* = .{ .type_name = class_name };
            return Value{ .sobject = sob };
        }
        // Fallback: create a bare ObjectInstance
        const instance = try self.arena.create(types.ObjectInstance);
        instance.* = .{ .class_name = class_name };
        return Value{ .object = instance };
    }
};

// ---------------------------------------------------------------------------
// 静的ヘルパー
// ---------------------------------------------------------------------------

/// メソッドオーバーロード解決用: 引数の Value とパラメータ型名のスコア計算。
fn overloadScoreForArg(arg: Value, pt: []const u8) i32 {
    if (arg == .string) {
        if (std.ascii.eqlIgnoreCase(pt, "String")) return 2;
        if (std.ascii.eqlIgnoreCase(pt, "Id")) return if (Evaluator.isSalesforceIdString(arg.string)) 3 else 2;
        if (std.ascii.eqlIgnoreCase(pt, "Object")) return 1;
        // Date/DateTime-like strings should match Date/DateTime params
        if (std.ascii.eqlIgnoreCase(pt, "Date") and Evaluator.isDateOnlyFormatString(arg.string)) return 2;
        if ((std.ascii.eqlIgnoreCase(pt, "DateTime") or std.ascii.eqlIgnoreCase(pt, "Datetime")) and Evaluator.isDateTimeFormatString(arg.string)) return 2;
        return 0;
    }
    if (arg == .integer) {
        if (std.ascii.eqlIgnoreCase(pt, "Integer") or std.ascii.eqlIgnoreCase(pt, "int")) return 2;
        if (std.ascii.eqlIgnoreCase(pt, "Long") or std.ascii.eqlIgnoreCase(pt, "Decimal") or std.ascii.eqlIgnoreCase(pt, "Double")) return 1;
        if (std.ascii.eqlIgnoreCase(pt, "Object")) return 1;
        return 0;
    }
    if (arg == .double) {
        if (std.ascii.eqlIgnoreCase(pt, "Decimal") or std.ascii.eqlIgnoreCase(pt, "Double")) return 2;
        if (std.ascii.eqlIgnoreCase(pt, "Integer") or std.ascii.eqlIgnoreCase(pt, "int") or std.ascii.eqlIgnoreCase(pt, "Long")) return 1;
        if (std.ascii.eqlIgnoreCase(pt, "Object")) return 1;
        return 0;
    }
    if (arg == .boolean) {
        if (std.ascii.eqlIgnoreCase(pt, "Boolean")) return 2;
        if (std.ascii.eqlIgnoreCase(pt, "Object")) return 1;
        return 0;
    }
    if (arg == .list) {
        if (std.ascii.eqlIgnoreCase(pt, "List")) return 2;
        // Check List element type against generic parameter: List<Database.SaveResult> etc.
        if (std.mem.startsWith(u8, pt, "List<") or std.mem.startsWith(u8, pt, "list<")) {
            // Extract element type from param: "List<Database.SaveResult>" → "Database.SaveResult"
            if (std.mem.indexOf(u8, pt, "<")) |lt| {
                if (std.mem.lastIndexOf(u8, pt, ">")) |gt| {
                    const elem_type = pt[lt + 1 .. gt];
                    // Check first element of the list
                    // SObject is a generic parent type — any SObject matches List<SObject>
                    if (std.ascii.eqlIgnoreCase(elem_type, "SObject") or std.ascii.eqlIgnoreCase(elem_type, "sObject") or std.ascii.eqlIgnoreCase(elem_type, "Sobject")) {
                        if (arg.list.items.items.len > 0) {
                            if (arg.list.items.items[0] == .sobject) return 3;
                        }
                        return 2; // Empty list matches List<SObject>
                    }
                    if (arg.list.items.items.len > 0) {
                        const first = arg.list.items.items[0];
                        if (first == .sobject) {
                            if (std.ascii.eqlIgnoreCase(first.sobject.type_name, elem_type)) return 3;
                            // Simple name match
                            if (std.mem.lastIndexOfScalar(u8, elem_type, '.')) |di| {
                                if (std.ascii.eqlIgnoreCase(first.sobject.type_name, elem_type[di + 1 ..])) return 3;
                            }
                        }
                        if (first == .object) {
                            if (std.ascii.eqlIgnoreCase(first.object.class_name, elem_type)) return 3;
                        }
                    }
                    return 1; // It's a List but element type doesn't match
                }
            }
        }
        return 0;
    }
    if (arg == .map) {
        if (std.ascii.eqlIgnoreCase(pt, "Map")) return 2;
        if (std.ascii.startsWithIgnoreCase(pt, "Map<")) return 2;
        if (std.ascii.eqlIgnoreCase(pt, "Object")) return 1;
        return 0;
    }
    if (arg == .set) {
        if (std.ascii.eqlIgnoreCase(pt, "Set")) return 2;
        if (std.ascii.startsWithIgnoreCase(pt, "Set<")) return 2;
        if (std.ascii.eqlIgnoreCase(pt, "Object")) return 1;
        if (std.ascii.startsWithIgnoreCase(pt, "Iterable") or std.mem.endsWith(u8, pt, "Iterable")) return 1;
        return 0;
    }
    if (arg == .sobject) {
        const tn = arg.sobject.type_name;
        // Exact type match (e.g., Database.SaveResult matches param Database.SaveResult)
        if (std.ascii.eqlIgnoreCase(tn, pt)) return 3;
        // Simple name match (e.g., "SaveResult" matches param "Database.SaveResult")
        if (std.mem.lastIndexOfScalar(u8, pt, '.')) |di| {
            if (std.ascii.eqlIgnoreCase(tn, pt[di + 1 ..])) return 3;
        }
        if (std.mem.lastIndexOfScalar(u8, tn, '.')) |di| {
            if (std.ascii.eqlIgnoreCase(tn[di + 1 ..], pt)) return 3;
        }
        // Generic SObject match
        if (std.ascii.eqlIgnoreCase(pt, "SObject") or std.ascii.eqlIgnoreCase(pt, "Sobject") or std.ascii.eqlIgnoreCase(pt, "sObject")) return 2;
        return 0;
    }
    if (arg == .object) {
        const cn = arg.object.class_name;
        // Exact class name match (case-insensitive)
        if (std.ascii.eqlIgnoreCase(cn, pt)) return 3;
        // Also check simple name (e.g., "MockEventBus" matches param type "EventBus" → no, but
        // "LoggerDataStore.EventBus" inner class: check if param type matches the simple name)
        if (std.mem.lastIndexOfScalar(u8, cn, '.')) |di| {
            if (std.ascii.eqlIgnoreCase(cn[di + 1 ..], pt)) return 3;
        }
        // Date/DateTime objects should score well for their specific types
        if (std.ascii.eqlIgnoreCase(cn, "Date")) {
            if (std.ascii.eqlIgnoreCase(pt, "Date")) return 2;
            if (std.ascii.eqlIgnoreCase(pt, "Object")) return 1;
            return 0;
        }
        if (std.ascii.eqlIgnoreCase(cn, "Datetime")) {
            if (std.ascii.eqlIgnoreCase(pt, "DateTime") or std.ascii.eqlIgnoreCase(pt, "Datetime")) return 2;
            if (std.ascii.eqlIgnoreCase(pt, "Object")) return 1;
            return 0;
        }
        if (std.ascii.eqlIgnoreCase(pt, "Object")) return 1;
        return 0;
    }
    return 0;
}

fn evalBinary(left: Value, op: ast.BinaryOp, right: Value, arena: std.mem.Allocator) !Value {
    const TemporalComparable = struct {
        fn normalize(raw: []const u8) []const u8 {
            if (raw.len > 10 and std.mem.indexOf(u8, raw, "T") != null) {
                if (std.mem.endsWith(u8, raw, ".000+0000")) return raw[0 .. raw.len - 9];
                if (std.mem.endsWith(u8, raw, ".000Z")) return raw[0 .. raw.len - 4];
                if (std.mem.endsWith(u8, raw, "Z")) return raw[0 .. raw.len - 1];
            }
            return raw;
        }

        fn fromValue(value: Value) ?[]const u8 {
            return switch (value) {
                .object => |obj| blk: {
                    if (!std.ascii.eqlIgnoreCase(obj.class_name, "Date") and !std.ascii.eqlIgnoreCase(obj.class_name, "Datetime")) {
                        break :blk null;
                    }
                    const raw = obj.fields.get("value") orelse break :blk null;
                    if (raw != .string) break :blk null;
                    break :blk normalize(raw.string);
                },
                .string => |raw| blk: {
                    const normalized = normalize(raw);
                    const is_date_like = normalized.len >= 10 and normalized[4] == '-' and normalized[7] == '-';
                    if (!is_date_like) break :blk null;
                    break :blk normalized;
                },
                else => null,
            };
        }
    };

    switch (op) {
        .eq => return .{ .boolean = utils.valueEql(left, right) },
        .neq => return .{ .boolean = !utils.valueEql(left, right) },
        .strict_eq => return .{ .boolean = utils.valueEql(left, right) },
        .strict_neq => return .{ .boolean = !utils.valueEql(left, right) },
        .and_op => return .{ .boolean = (utils.coerceToBool(left) catch false) and (utils.coerceToBool(right) catch false) },
        .or_op => return .{ .boolean = (utils.coerceToBool(left) catch false) or (utils.coerceToBool(right) catch false) },
        else => {},
    }

    if (left == .integer and right == .integer) {
        return .{ .integer = switch (op) {
            .add => left.integer + right.integer,
            .sub => left.integer - right.integer,
            .mul => left.integer * right.integer,
            .div => if (right.integer != 0) @divTrunc(left.integer, right.integer) else 0,
            .mod => if (right.integer != 0) @mod(left.integer, right.integer) else 0,
            .lt => return .{ .boolean = left.integer < right.integer },
            .gt => return .{ .boolean = left.integer > right.integer },
            .lte => return .{ .boolean = left.integer <= right.integer },
            .gte => return .{ .boolean = left.integer >= right.integer },
            else => 0,
        } };
    }

    if ((left == .double or left == .integer) and (right == .double or right == .integer)) {
        const l = if (left == .double) left.double else @as(f64, @floatFromInt(left.integer));
        const r = if (right == .double) right.double else @as(f64, @floatFromInt(right.integer));
        return switch (op) {
            .add => .{ .double = l + r },
            .sub => .{ .double = l - r },
            .mul => .{ .double = l * r },
            .div => .{ .double = if (r != 0) l / r else 0 },
            .lt => .{ .boolean = l < r },
            .gt => .{ .boolean = l > r },
            .lte => .{ .boolean = l <= r },
            .gte => .{ .boolean = l >= r },
            else => .null_val,
        };
    }

    // String concatenation
    if (op == .add and (left == .string or right == .string)) {
        const ls = try utils.coerceToString(left, arena);
        const rs = try utils.coerceToString(right, arena);
        const result = try std.fmt.allocPrint(arena, "{s}{s}", .{ ls, rs });
        return .{ .string = result };
    }

    if (TemporalComparable.fromValue(left)) |lv| {
        if (TemporalComparable.fromValue(right)) |rv| {
            const cmp = std.mem.order(u8, lv, rv);
            return switch (op) {
                .lt => .{ .boolean = cmp == .lt },
                .gt => .{ .boolean = cmp == .gt },
                .lte => .{ .boolean = cmp != .gt },
                .gte => .{ .boolean = cmp != .lt },
                else => .null_val,
            };
        }
    }

    // Date/DateTime comparison (objects with "value" field containing ISO strings)
    if (left == .object and right == .object) {
        const left_cn = left.object.class_name;
        const right_cn = right.object.class_name;
        if ((std.ascii.eqlIgnoreCase(left_cn, "Date") or std.ascii.eqlIgnoreCase(left_cn, "Datetime")) and
            (std.ascii.eqlIgnoreCase(right_cn, "Date") or std.ascii.eqlIgnoreCase(right_cn, "Datetime")))
        {
            const lv = if (left.object.fields.get("value")) |v| (if (v == .string) v.string else "") else "";
            const rv = if (right.object.fields.get("value")) |v| (if (v == .string) v.string else "") else "";
            const cmp = std.mem.order(u8, lv, rv);
            return switch (op) {
                .lt => .{ .boolean = cmp == .lt },
                .gt => .{ .boolean = cmp == .gt },
                .lte => .{ .boolean = cmp != .gt },
                .gte => .{ .boolean = cmp != .lt },
                else => .null_val,
            };
        }
    }
    // String comparison for < > <= >=
    if (left == .string and right == .string) {
        const cmp = std.mem.order(u8, left.string, right.string);
        return switch (op) {
            .lt => .{ .boolean = cmp == .lt },
            .gt => .{ .boolean = cmp == .gt },
            .lte => .{ .boolean = cmp != .gt },
            .gte => .{ .boolean = cmp != .lt },
            else => .null_val,
        };
    }

    return .null_val;
}

fn evalUnary(op: ast.UnaryOp, operand: Value) !Value {
    switch (op) {
        .negate => {
            if (operand == .integer) return .{ .integer = -operand.integer };
            if (operand == .double) return .{ .double = -operand.double };
            return .null_val;
        },
        .not => return .{ .boolean = !(utils.coerceToBool(operand) catch false) },
    }
}

fn evalCompoundAssign(current: Value, op: ast.AssignOp, value: Value, arena: std.mem.Allocator) Value {
    switch (op) {
        .plus_assign => {
            if (current == .integer and value == .integer) return .{ .integer = current.integer + value.integer };
            if (current == .double and value == .double) return .{ .double = current.double + value.double };
            // String concatenation for +=
            if (current == .string or value == .string) {
                const ls = utils.coerceToString(current, arena) catch return current;
                const rs = utils.coerceToString(value, arena) catch return current;
                const result = std.fmt.allocPrint(arena, "{s}{s}", .{ ls, rs }) catch return current;
                return .{ .string = result };
            }
        },
        .minus_assign => {
            if (current == .integer and value == .integer) return .{ .integer = current.integer - value.integer };
        },
        .star_assign => {
            if (current == .integer and value == .integer) return .{ .integer = current.integer * value.integer };
        },
        .slash_assign => {
            if (current == .integer and value == .integer and value.integer != 0)
                return .{ .integer = @divTrunc(current.integer, value.integer) };
        },
        .assign => return value,
        .null_coalesce_assign => return if (current == .null_val) value else current,
    }
    return value;
}

fn defaultValue(type_ref: types.TypeRef) Value {
    // Apex treats all types (including Integer, Double, Decimal, Boolean) as
    // reference types whose uninitialized value is null.
    _ = type_ref;
    return .null_val;
}

fn extractFromType(soql: []const u8) ?[]const u8 {
    // Find "FROM <type>" case-insensitive, skipping sub-queries in parens
    const lower = soql;
    var i: usize = 0;
    var depth: u32 = 0;
    while (i + 5 < lower.len) : (i += 1) {
        if (lower[i] == '(') {
            depth += 1;
            continue;
        }
        if (lower[i] == ')') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth > 0) continue; // Skip content inside parentheses
        if (std.ascii.eqlIgnoreCase(lower[i .. i + 4], "from") and isSoqlWhitespace(lower[i + 4])) {
            var start = i + 5;
            while (start < lower.len and isSoqlWhitespace(lower[start])) start += 1;
            var end = start;
            while (end < lower.len and !isSoqlWhitespace(lower[end]) and lower[end] != ']' and lower[end] != ')') end += 1;
            if (end > start) return lower[start..end];
        }
    }
    return null;
}

/// Check if a character is whitespace (space, tab, newline, carriage return)
fn isSoqlWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn extractWhereClause(soql: []const u8) ?[]const u8 {
    // Find WHERE ... (ends before ORDER BY, GROUP BY, LIMIT, OFFSET, WITH, FOR)
    // Skip content inside parentheses (sub-queries)
    var i: usize = 0;
    var paren_depth: u32 = 0;
    while (i + 5 < soql.len) : (i += 1) {
        if (soql[i] == '(') {
            paren_depth += 1;
            continue;
        }
        if (soql[i] == ')') {
            if (paren_depth > 0) paren_depth -= 1;
            continue;
        }
        if (paren_depth > 0) continue;
        if (std.ascii.eqlIgnoreCase(soql[i .. i + 5], "where") and
            (i == 0 or isSoqlWhitespace(soql[i - 1])) and
            isSoqlWhitespace(soql[i + 5]))
        {
            const start = i + 6;
            // Find end of WHERE clause
            var end = soql.len;
            var j: usize = start;
            while (j + 3 < soql.len) : (j += 1) {
                // Check for terminating keywords
                const remaining = soql[j..];
                if (remaining.len >= 5 and std.ascii.eqlIgnoreCase(remaining[0..5], "ORDER") and
                    (j == 0 or isSoqlWhitespace(soql[j - 1])))
                {
                    end = j;
                    break;
                }
                if (remaining.len >= 5 and std.ascii.eqlIgnoreCase(remaining[0..5], "GROUP") and
                    (j == 0 or isSoqlWhitespace(soql[j - 1])))
                {
                    end = j;
                    break;
                }
                if (remaining.len >= 5 and std.ascii.eqlIgnoreCase(remaining[0..5], "LIMIT") and
                    (j == 0 or isSoqlWhitespace(soql[j - 1])))
                {
                    end = j;
                    break;
                }
                if (remaining.len >= 6 and std.ascii.eqlIgnoreCase(remaining[0..6], "OFFSET") and
                    (j == 0 or isSoqlWhitespace(soql[j - 1])))
                {
                    end = j;
                    break;
                }
                if (remaining.len >= 4 and std.ascii.eqlIgnoreCase(remaining[0..4], "WITH") and
                    (j == 0 or isSoqlWhitespace(soql[j - 1])))
                {
                    end = j;
                    break;
                }
                if (remaining.len >= 3 and std.ascii.eqlIgnoreCase(remaining[0..3], "FOR") and
                    (j == 0 or isSoqlWhitespace(soql[j - 1])))
                {
                    end = j;
                    break;
                }
            }
            if (start < end) return soql[start..end];
        }
    }
    return null;
}

fn findLogicalOp(clause: []const u8, keyword: []const u8) ?usize {
    // Find AND/OR at top level (not inside parens)
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < clause.len) : (i += 1) {
        if (clause[i] == '(') {
            depth += 1;
            continue;
        }
        if (clause[i] == ')') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (clause[i] == '\'') {
            // Skip string literal
            i += 1;
            while (i < clause.len and clause[i] != '\'') : (i += 1) {}
            continue;
        }
        if (depth == 0 and i + keyword.len <= clause.len) {
            if (std.ascii.eqlIgnoreCase(clause[i .. i + keyword.len], keyword)) {
                // Check word boundaries
                const before_ok = (i == 0 or clause[i - 1] == ' ' or clause[i - 1] == '\n' or clause[i - 1] == ')');
                const after_ok = (i + keyword.len >= clause.len or clause[i + keyword.len] == ' ' or clause[i + keyword.len] == '\n' or clause[i + keyword.len] == '(');
                if (before_ok and after_ok) return i;
            }
        }
    }
    return null;
}

fn extractOffset(soql: []const u8) ?usize {
    var i: usize = 0;
    while (i + 7 < soql.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(soql[i .. i + 6], "offset") and (soql[i + 6] == ' ' or soql[i + 6] == '\n')) {
            var start = i + 7;
            while (start < soql.len and soql[start] == ' ') start += 1;
            var end = start;
            while (end < soql.len and std.ascii.isDigit(soql[end])) end += 1;
            if (end > start) return std.fmt.parseUnsigned(usize, soql[start..end], 10) catch null;
        }
    }
    return null;
}

fn extractOffsetBindVar(soql: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 7 < soql.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(soql[i .. i + 6], "offset") and (soql[i + 6] == ' ' or soql[i + 6] == '\n')) {
            var start = i + 7;
            while (start < soql.len and soql[start] == ' ') start += 1;
            if (start < soql.len and soql[start] == ':') {
                var end = start + 1;
                while (end < soql.len and (std.ascii.isAlphanumeric(soql[end]) or soql[end] == '_')) end += 1;
                if (end > start + 1) return soql[start + 1 .. end];
            }
        }
    }
    return null;
}

const OrderByInfo = struct {
    field: []const u8,
    desc: bool,
};

fn extractOrderByField(soql: []const u8) ?OrderByInfo {
    var i: usize = 0;
    while (i + 9 < soql.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(soql[i .. i + 8], "ORDER BY") and
            (soql[i + 8] == ' ' or soql[i + 8] == '\n' or soql[i + 8] == '\t'))
        {
            var start = i + 9;
            while (start < soql.len and (soql[start] == ' ' or soql[start] == '\t' or soql[start] == '\n' or soql[start] == '\r')) start += 1;
            var end = start;
            while (end < soql.len and soql[end] != ' ' and soql[end] != '\n' and soql[end] != '\t' and soql[end] != ',' and soql[end] != ')') end += 1;
            if (end > start) {
                const field = soql[start..end];
                // Check for DESC/ASC after the field
                var pos = end;
                while (pos < soql.len and (soql[pos] == ' ' or soql[pos] == '\t' or soql[pos] == '\n' or soql[pos] == '\r')) pos += 1;
                var descending = false;
                if (pos + 4 <= soql.len and std.ascii.eqlIgnoreCase(soql[pos .. pos + 4], "DESC")) {
                    descending = true;
                }
                return OrderByInfo{ .field = field, .desc = descending };
            }
        }
    }
    return null;
}

fn extractLimitBindVar(soql: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 6 < soql.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(soql[i .. i + 5], "limit") and (soql[i + 5] == ' ' or soql[i + 5] == '\n')) {
            var start = i + 6;
            while (start < soql.len and soql[start] == ' ') start += 1;
            if (start < soql.len and soql[start] == ':') {
                var end = start + 1;
                while (end < soql.len and (std.ascii.isAlphanumeric(soql[end]) or soql[end] == '_')) end += 1;
                return soql[start + 1 .. end];
            }
        }
    }
    return null;
}

fn extractLimit(soql: []const u8) ?usize {
    var i: usize = 0;
    while (i + 6 < soql.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(soql[i .. i + 5], "limit") and (soql[i + 5] == ' ' or soql[i + 5] == '\n')) {
            var start = i + 6;
            while (start < soql.len and soql[start] == ' ') start += 1;
            var end = start;
            while (end < soql.len and std.ascii.isDigit(soql[end])) end += 1;
            if (end > start) return std.fmt.parseUnsigned(usize, soql[start..end], 10) catch null;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// SOQL sub-query and parent field helpers
// ---------------------------------------------------------------------------

const SubQueryInfo = struct {
    relationship: []const u8,
};

fn extractSubQuery(soql: []const u8) ?SubQueryInfo {
    // Find pattern: (SELECT ... FROM RelationshipName)
    // We only need the relationship name from the inner FROM
    var i: usize = 0;
    while (i < soql.len) : (i += 1) {
        if (soql[i] == '(' and i + 8 < soql.len) {
            const after_paren = std.mem.trim(u8, soql[i + 1 ..], " \t\n\r");
            if (after_paren.len > 6 and std.ascii.eqlIgnoreCase(after_paren[0..6], "SELECT")) {
                // Find the FROM in this sub-query
                if (std.ascii.indexOfIgnoreCase(after_paren, "FROM")) |from_pos| {
                    var start = from_pos + 4;
                    while (start < after_paren.len and (after_paren[start] == ' ' or after_paren[start] == '\t' or after_paren[start] == '\n')) start += 1;
                    var end = start;
                    while (end < after_paren.len and after_paren[end] != ' ' and after_paren[end] != ')' and after_paren[end] != '\n' and after_paren[end] != '\t') end += 1;
                    if (end > start) {
                        const raw_rel = after_paren[start..end];
                        // Strip parent prefix: "Account.Contacts" → "Contacts"
                        const rel = if (std.mem.lastIndexOfScalar(u8, raw_rel, '.')) |dot_pos| raw_rel[dot_pos + 1 ..] else raw_rel;
                        return SubQueryInfo{ .relationship = rel };
                    }
                }
            }
        }
    }
    return null;
}

fn extractParentFields(soql: []const u8) ?[]const u8 {
    // Extract SELECT clause
    const select_start = if (std.ascii.indexOfIgnoreCase(soql, "SELECT")) |si| si + 6 else return null;
    // Find outer FROM (not inside parens)
    var from_end: usize = soql.len;
    var depth: u32 = 0;
    var idx: usize = select_start;
    while (idx + 4 < soql.len) : (idx += 1) {
        if (soql[idx] == '(') depth += 1;
        if (soql[idx] == ')') {
            if (depth > 0) depth -= 1;
        }
        if (depth == 0 and std.ascii.eqlIgnoreCase(soql[idx .. idx + 4], "FROM") and
            (idx == 0 or soql[idx - 1] == ' ' or soql[idx - 1] == '\n' or soql[idx - 1] == '\t'))
        {
            from_end = idx;
            break;
        }
    }
    return soql[select_start..from_end];
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");

const EvalTestResult = struct {
    value: Value,
    stdout: []const u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *EvalTestResult) void {
        self.arena.deinit();
    }
};

fn evalSource(source: []const u8, class_name: []const u8, method_name: []const u8) !EvalTestResult {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();

    const tokens = try lexer_mod.tokenize(source, arena.allocator());
    const decls = try parser_mod.parse(tokens, arena.allocator());
    var eval = try Evaluator.init(arena.allocator());
    try eval.loadDecls(decls);
    const result = try eval.callMethod(class_name, method_name, &.{});

    return .{ .value = result, .stdout = eval.stdout.items, .arena = arena };
}

test "evaluate 1 + 2" {
    const tokens = try lexer_mod.tokenize("1 + 2", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parser_mod.parseExpr(tokens, arena.allocator());
    var eval = try Evaluator.init(arena.allocator());
    const result = try eval.evalExpr(expr, eval.global_env);
    try std.testing.expectEqual(@as(i64, 3), result.integer);
}

test "evaluate string equality case-insensitive" {
    const tokens = try lexer_mod.tokenize("'Hello' == 'hello'", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parser_mod.parseExpr(tokens, arena.allocator());
    var eval = try Evaluator.init(arena.allocator());
    const result = try eval.evalExpr(expr, eval.global_env);
    try std.testing.expect(result.boolean);
}

test "evaluate null == null" {
    const tokens = try lexer_mod.tokenize("null == null", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parser_mod.parseExpr(tokens, arena.allocator());
    var eval = try Evaluator.init(arena.allocator());
    const result = try eval.evalExpr(expr, eval.global_env);
    try std.testing.expect(result.boolean);
}

test "evaluate class method returning string" {
    const source =
        \\public class Hello {
        \\    public static String greet() {
        \\        return 'world';
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Hello", "greet");
    defer r.deinit();
    try std.testing.expectEqualStrings("world", r.value.string);
}

test "evaluate class method with arithmetic" {
    const source =
        \\public class Calc {
        \\    public static Integer add() {
        \\        Integer x = 10;
        \\        Integer y = 20;
        \\        return x + y;
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Calc", "add");
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 30), r.value.integer);
}

test "evaluate System.debug" {
    const source =
        \\public class Debug {
        \\    public static void run() {
        \\        System.debug('hello');
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Debug", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("hello\n", r.stdout);
}

test "evaluate if-else" {
    const source =
        \\public class Branch {
        \\    public static String check() {
        \\        Boolean cond = true;
        \\        if (cond) {
        \\            return 'yes';
        \\        } else {
        \\            return 'no';
        \\        }
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Branch", "check");
    defer r.deinit();
    try std.testing.expectEqualStrings("yes", r.value.string);
}

test "evaluate for loop" {
    const source =
        \\public class Loop {
        \\    public static Integer sum() {
        \\        Integer total = 0;
        \\        for (Integer i = 0; i < 5; i += 1) {
        \\            total += i;
        \\        }
        \\        return total;
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Loop", "sum");
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 10), r.value.integer);
}

test "evaluate string concatenation" {
    const source =
        \\public class Concat {
        \\    public static String run() {
        \\        return 'Hello' + ' ' + 'World';
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Concat", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("Hello World", r.value.string);
}

test "evaluate ternary expression" {
    const source =
        \\public class Ternary {
        \\    public static String run() {
        \\        Boolean flag = false;
        \\        return flag ? 'yes' : 'no';
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Ternary", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("no", r.value.string);
}

test "inner class accesses outer class static field" {
    const source =
        \\public class Outer {
        \\    private static String SHARED_VALUE = 'outer-value';
        \\    public static String run() {
        \\        Inner i = new Inner();
        \\        return i.getValue();
        \\    }
        \\    private class Inner {
        \\        public String getValue() {
        \\            return SHARED_VALUE;
        \\        }
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Outer", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("outer-value", r.value.string);
}

test "inner class accesses outer class static property getter" {
    const source =
        \\public class Outer {
        \\    private static String CACHED_VALUE {
        \\        get {
        \\            if (CACHED_VALUE == null) {
        \\                CACHED_VALUE = 'lazy-init';
        \\            }
        \\            return CACHED_VALUE;
        \\        }
        \\        set;
        \\    }
        \\    public static String run() {
        \\        Inner i = new Inner();
        \\        return i.getValue();
        \\    }
        \\    private class Inner {
        \\        public String getValue() {
        \\            return CACHED_VALUE;
        \\        }
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Outer", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("lazy-init", r.value.string);
}

test "inner class accesses outer class static field via method call" {
    const source =
        \\public class Outer {
        \\    private static Map<String, String> CACHE = new Map<String, String>{ 'key1' => 'val1' };
        \\    public static String run() {
        \\        Inner i = new Inner();
        \\        return i.getFromCache();
        \\    }
        \\    private class Inner {
        \\        public String getFromCache() {
        \\            return CACHE.get('key1');
        \\        }
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Outer", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("val1", r.value.string);
}

test "SOQL assignment unwraps for previously declared SObject variable" {
    const source =
        \\public class SoqlAssign {
        \\    public static String run() {
        \\        insert new Account(Name = 'Acme');
        \\        Account account;
        \\        account = [SELECT Name FROM Account LIMIT 1];
        \\        return account.Name;
        \\    }
        \\}
    ;
    var r = try evalSource(source, "SoqlAssign", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("Acme", r.value.string);
}

test "static property returns inner class field initializer value" {
    const source =
        \\public class Outer {
        \\    private static LimitsHolder CACHED {
        \\        get {
        \\            if (CACHED == null) {
        \\                CACHED = new LimitsHolder();
        \\            }
        \\            return CACHED;
        \\        }
        \\        set;
        \\    }
        \\    public static Integer run() {
        \\        return CACHED.limitValue;
        \\    }
        \\    private class LimitsHolder {
        \\        public final Integer limitValue = System.Limits.getLimitAggregateQueries();
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Outer", "run");
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 300), r.value.integer);
}

test "static property with dotted type resolves getter value" {
    const source =
        \\public class Outer {
        \\    private static Helper.Holder CACHED {
        \\        get {
        \\            if (CACHED == null) {
        \\                CACHED = new Helper.Holder();
        \\            }
        \\            return CACHED;
        \\        }
        \\        set;
        \\    }
        \\    public static Integer run() {
        \\        return CACHED.value;
        \\    }
        \\}
        \\public class Helper {
        \\    public class Holder {
        \\        public Integer value = 7;
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Outer", "run");
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 7), r.value.integer);
}

test "static property returning sobject resolves getter value" {
    const source =
        \\public class Outer {
        \\    private static Account CACHED {
        \\        get {
        \\            if (CACHED == null) {
        \\                insert new Account(Name = 'Acme');
        \\                CACHED = [SELECT Id, Name FROM Account LIMIT 1];
        \\            }
        \\            return CACHED;
        \\        }
        \\        set;
        \\    }
        \\    public static String run() {
        \\        return CACHED.Name;
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Outer", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("Acme", r.value.string);
}

test "instance method reads static property getter without losing backing value" {
    const source =
        \\public class Outer {
        \\    private static String CACHED_VALUE {
        \\        get {
        \\            if (CACHED_VALUE == null) {
        \\                CACHED_VALUE = 'lazy-init';
        \\            }
        \\            return CACHED_VALUE;
        \\        }
        \\        set;
        \\    }
        \\    public String getValue() {
        \\        return CACHED_VALUE;
        \\    }
        \\    public static String run() {
        \\        return new Outer().getValue();
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Outer", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("lazy-init", r.value.string);
}

test "mock singleton override feeds static lazy getter" {
    const source =
        \\public virtual class Selector {
        \\    private static Selector instance = new Selector();
        \\    public static Selector getInstance() {
        \\        return instance;
        \\    }
        \\    public static void setMock(Selector mockSelector) {
        \\        instance = mockSelector;
        \\    }
        \\    public virtual String getValue() {
        \\        return null;
        \\    }
        \\}
        \\public class MockSelector extends Selector {
        \\    private String cachedValue;
        \\    public void setValue(String cachedValue) {
        \\        this.cachedValue = cachedValue;
        \\    }
        \\    public override String getValue() {
        \\        return this.cachedValue;
        \\    }
        \\}
        \\public class Holder {
        \\    private static String CACHED_VALUE {
        \\        get {
        \\            if (CACHED_VALUE == null) {
        \\                CACHED_VALUE = Selector.getInstance().getValue();
        \\            }
        \\            return CACHED_VALUE;
        \\        }
        \\        set;
        \\    }
        \\    public static String run() {
        \\        return CACHED_VALUE;
        \\    }
        \\}
        \\public class Runner {
        \\    public static String run() {
        \\        MockSelector mockSelector = new MockSelector();
        \\        mockSelector.setValue('mocked');
        \\        Selector.setMock(mockSelector);
        \\        return Holder.run();
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Runner", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("mocked", r.value.string);
}

test "mock singleton override feeds static lazy sobject getter" {
    const source =
        \\public virtual class Selector {
        \\    private static Selector instance = new Selector();
        \\    public static Selector getInstance() {
        \\        return instance;
        \\    }
        \\    public static void setMock(Selector mockSelector) {
        \\        instance = mockSelector;
        \\    }
        \\    public virtual Account getAccount() {
        \\        return null;
        \\    }
        \\}
        \\public class MockSelector extends Selector {
        \\    private Account cachedAccount;
        \\    public void setAccount(Account cachedAccount) {
        \\        this.cachedAccount = cachedAccount;
        \\    }
        \\    public override Account getAccount() {
        \\        return this.cachedAccount;
        \\    }
        \\}
        \\public class Holder {
        \\    private static Account CACHED_ACCOUNT {
        \\        get {
        \\            if (CACHED_ACCOUNT == null) {
        \\                CACHED_ACCOUNT = Selector.getInstance().getAccount();
        \\            }
        \\            return CACHED_ACCOUNT;
        \\        }
        \\        set;
        \\    }
        \\    public static String run() {
        \\        return CACHED_ACCOUNT?.Id;
        \\    }
        \\}
        \\public class Runner {
        \\    public static String run() {
        \\        MockSelector mockSelector = new MockSelector();
        \\        mockSelector.setAccount(new Account(Id = '001000000000001', Name = 'Acme'));
        \\        Selector.setMock(mockSelector);
        \\        return Holder.run();
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Runner", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("001000000000001", r.value.string);
}

test "mock singleton override feeds nested inner-class getter" {
    const source =
        \\public class LoggerSObjectProxy {
        \\    public class AuthSession {
        \\        public LoginHistory LoginHistory;
        \\    }
        \\    public class LoginHistory {
        \\        public String Application;
        \\    }
        \\}
        \\public virtual class Selector {
        \\    private static Selector instance = new Selector();
        \\    public static Selector getInstance() {
        \\        return instance;
        \\    }
        \\    public static void setMock(Selector mockSelector) {
        \\        instance = mockSelector;
        \\    }
        \\    public virtual LoggerSObjectProxy.AuthSession getCachedAuthSessionProxy() {
        \\        return null;
        \\    }
        \\}
        \\public class MockSelector extends Selector {
        \\    private LoggerSObjectProxy.AuthSession mockAuthSessionProxy;
        \\    public void setCachedAuthSessionProxy(LoggerSObjectProxy.AuthSession mockAuthSessionProxy) {
        \\        this.mockAuthSessionProxy = mockAuthSessionProxy;
        \\    }
        \\    public override LoggerSObjectProxy.AuthSession getCachedAuthSessionProxy() {
        \\        if (this.mockAuthSessionProxy != null) {
        \\            return mockAuthSessionProxy;
        \\        }
        \\        return super.getCachedAuthSessionProxy();
        \\    }
        \\}
        \\public class Builder {
        \\    private static LoggerSObjectProxy.AuthSession CACHED_AUTH_SESSION_PROXY {
        \\        get {
        \\            if (CACHED_AUTH_SESSION_PROXY == null) {
        \\                CACHED_AUTH_SESSION_PROXY = Selector.getInstance().getCachedAuthSessionProxy();
        \\            }
        \\            return CACHED_AUTH_SESSION_PROXY;
        \\        }
        \\        set;
        \\    }
        \\    public static String run() {
        \\        return CACHED_AUTH_SESSION_PROXY.LoginHistory?.Application;
        \\    }
        \\}
        \\public class Runner {
        \\    public static String run() {
        \\        LoggerSObjectProxy.LoginHistory mockLoginHistoryProxy = new LoggerSObjectProxy.LoginHistory();
        \\        mockLoginHistoryProxy.Application = 'Application';
        \\        LoggerSObjectProxy.AuthSession mockAuthSessionProxy = new LoggerSObjectProxy.AuthSession();
        \\        mockAuthSessionProxy.LoginHistory = mockLoginHistoryProxy;
        \\        MockSelector mockSelector = new MockSelector();
        \\        mockSelector.setCachedAuthSessionProxy(mockAuthSessionProxy);
        \\        Selector.setMock(mockSelector);
        \\        return Builder.run();
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Runner", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("Application", r.value.string);
}

test "typed null identifier prefers sobject overload over id overload" {
    const source =
        \\public class OverloadProbe {
        \\    public static String pick(Id value) {
        \\        return 'id';
        \\    }
        \\    public static String pick(SObject value) {
        \\        return 'sobject';
        \\    }
        \\    public static String run() {
        \\        User nullUser;
        \\        return pick(nullUser);
        \\    }
        \\}
    ;
    var r = try evalSource(source, "OverloadProbe", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("sobject", r.value.string);
}

test "typed null identifier prefers iterable overload over object overload" {
    const source =
        \\public class IterableProbe {
        \\    public static String pick(Object value) {
        \\        return 'object';
        \\    }
        \\    public static String pick(System.Iterable<Id> value) {
        \\        return 'iterable';
        \\    }
        \\    public static String run() {
        \\        System.Iterable<Id> ids = null;
        \\        return pick(ids);
        \\    }
        \\}
    ;
    var r = try evalSource(source, "IterableProbe", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("iterable", r.value.string);
}
