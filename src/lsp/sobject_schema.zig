//! sobject_schema — SObject フィールドカタログ。
//!
//! 標準 SObject のフィールド定義（ビルトイン）と
//! .object-meta.xml からのカスタムフィールド読み込みを提供する。

const std = @import("std");

pub const FieldInfo = struct {
    name: []const u8,
    type_name: []const u8, // "String", "Id", "Date", "Double", "Boolean", etc.
};

pub const SObjectSchema = struct {
    name: []const u8,
    fields: []const FieldInfo,
};

// ---------------------------------------------------------------------------
// 標準 SObject フィールド定義
// ---------------------------------------------------------------------------

const common_fields = [_]FieldInfo{
    .{ .name = "Id", .type_name = "Id" },
    .{ .name = "Name", .type_name = "String" },
    .{ .name = "CreatedDate", .type_name = "Datetime" },
    .{ .name = "CreatedById", .type_name = "Id" },
    .{ .name = "LastModifiedDate", .type_name = "Datetime" },
    .{ .name = "LastModifiedById", .type_name = "Id" },
    .{ .name = "SystemModstamp", .type_name = "Datetime" },
    .{ .name = "IsDeleted", .type_name = "Boolean" },
    .{ .name = "OwnerId", .type_name = "Id" },
};

const account_fields = common_fields ++ [_]FieldInfo{
    .{ .name = "AccountNumber", .type_name = "String" },
    .{ .name = "AnnualRevenue", .type_name = "Decimal" },
    .{ .name = "BillingCity", .type_name = "String" },
    .{ .name = "BillingCountry", .type_name = "String" },
    .{ .name = "BillingPostalCode", .type_name = "String" },
    .{ .name = "BillingState", .type_name = "String" },
    .{ .name = "BillingStreet", .type_name = "String" },
    .{ .name = "Description", .type_name = "String" },
    .{ .name = "Fax", .type_name = "String" },
    .{ .name = "Industry", .type_name = "String" },
    .{ .name = "NumberOfEmployees", .type_name = "Integer" },
    .{ .name = "ParentId", .type_name = "Id" },
    .{ .name = "Phone", .type_name = "String" },
    .{ .name = "Rating", .type_name = "String" },
    .{ .name = "ShippingCity", .type_name = "String" },
    .{ .name = "ShippingCountry", .type_name = "String" },
    .{ .name = "ShippingPostalCode", .type_name = "String" },
    .{ .name = "ShippingState", .type_name = "String" },
    .{ .name = "ShippingStreet", .type_name = "String" },
    .{ .name = "Site", .type_name = "String" },
    .{ .name = "Type", .type_name = "String" },
    .{ .name = "Website", .type_name = "String" },
};

const contact_fields = common_fields ++ [_]FieldInfo{
    .{ .name = "AccountId", .type_name = "Id" },
    .{ .name = "Birthdate", .type_name = "Date" },
    .{ .name = "Department", .type_name = "String" },
    .{ .name = "Email", .type_name = "String" },
    .{ .name = "FirstName", .type_name = "String" },
    .{ .name = "LastName", .type_name = "String" },
    .{ .name = "MailingCity", .type_name = "String" },
    .{ .name = "MailingCountry", .type_name = "String" },
    .{ .name = "MailingPostalCode", .type_name = "String" },
    .{ .name = "MailingState", .type_name = "String" },
    .{ .name = "MailingStreet", .type_name = "String" },
    .{ .name = "MobilePhone", .type_name = "String" },
    .{ .name = "Phone", .type_name = "String" },
    .{ .name = "Title", .type_name = "String" },
};

const opportunity_fields = common_fields ++ [_]FieldInfo{
    .{ .name = "AccountId", .type_name = "Id" },
    .{ .name = "Amount", .type_name = "Decimal" },
    .{ .name = "CloseDate", .type_name = "Date" },
    .{ .name = "Description", .type_name = "String" },
    .{ .name = "ForecastCategory", .type_name = "String" },
    .{ .name = "IsClosed", .type_name = "Boolean" },
    .{ .name = "IsWon", .type_name = "Boolean" },
    .{ .name = "LeadSource", .type_name = "String" },
    .{ .name = "NextStep", .type_name = "String" },
    .{ .name = "Probability", .type_name = "Double" },
    .{ .name = "StageName", .type_name = "String" },
    .{ .name = "Type", .type_name = "String" },
};

const lead_fields = common_fields ++ [_]FieldInfo{
    .{ .name = "Company", .type_name = "String" },
    .{ .name = "Email", .type_name = "String" },
    .{ .name = "FirstName", .type_name = "String" },
    .{ .name = "LastName", .type_name = "String" },
    .{ .name = "Phone", .type_name = "String" },
    .{ .name = "Status", .type_name = "String" },
    .{ .name = "Title", .type_name = "String" },
    .{ .name = "Industry", .type_name = "String" },
    .{ .name = "LeadSource", .type_name = "String" },
};

const case_fields = common_fields ++ [_]FieldInfo{
    .{ .name = "AccountId", .type_name = "Id" },
    .{ .name = "ContactId", .type_name = "Id" },
    .{ .name = "Description", .type_name = "String" },
    .{ .name = "IsClosed", .type_name = "Boolean" },
    .{ .name = "Origin", .type_name = "String" },
    .{ .name = "Priority", .type_name = "String" },
    .{ .name = "Reason", .type_name = "String" },
    .{ .name = "Status", .type_name = "String" },
    .{ .name = "Subject", .type_name = "String" },
    .{ .name = "Type", .type_name = "String" },
};

const task_fields = common_fields ++ [_]FieldInfo{
    .{ .name = "ActivityDate", .type_name = "Date" },
    .{ .name = "Description", .type_name = "String" },
    .{ .name = "Priority", .type_name = "String" },
    .{ .name = "Status", .type_name = "String" },
    .{ .name = "Subject", .type_name = "String" },
    .{ .name = "WhatId", .type_name = "Id" },
    .{ .name = "WhoId", .type_name = "Id" },
};

const user_fields = common_fields ++ [_]FieldInfo{
    .{ .name = "Alias", .type_name = "String" },
    .{ .name = "Email", .type_name = "String" },
    .{ .name = "FirstName", .type_name = "String" },
    .{ .name = "LastName", .type_name = "String" },
    .{ .name = "IsActive", .type_name = "Boolean" },
    .{ .name = "ProfileId", .type_name = "Id" },
    .{ .name = "Username", .type_name = "String" },
    .{ .name = "UserRoleId", .type_name = "Id" },
};

/// ビルトイン標準 SObject 一覧。
const builtin_schemas = [_]SObjectSchema{
    .{ .name = "Account", .fields = &account_fields },
    .{ .name = "Contact", .fields = &contact_fields },
    .{ .name = "Opportunity", .fields = &opportunity_fields },
    .{ .name = "Lead", .fields = &lead_fields },
    .{ .name = "Case", .fields = &case_fields },
    .{ .name = "Task", .fields = &task_fields },
    .{ .name = "User", .fields = &user_fields },
};

/// ワークスペースから読み込んだカスタムフィールドを保持するレジストリ。
pub const CustomFieldRegistry = struct {
    /// オブジェクト名 → フィールド一覧
    objects: std.StringHashMap([]FieldInfo),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) CustomFieldRegistry {
        return .{
            .objects = std.StringHashMap([]FieldInfo).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *CustomFieldRegistry) void {
        self.objects.deinit();
        self.arena.deinit();
    }

    /// ワークスペースの objects/ ディレクトリからカスタムフィールドを読み込む。
    pub fn load_from_workspace(self: *CustomFieldRegistry, io: std.Io, workspace_path: []const u8) !void {
        const alloc = self.arena.allocator();
        const sfdx_project = @import("sfdx_project.zig");

        // sfdx-project.json の packageDirectories からソースルートを動的に解決
        const pkg_dirs = try sfdx_project.resolve_package_dirs(alloc, io, workspace_path);
        // arena で確保しているため個別 free は不要

        const objects_dirs = try sfdx_project.resolve_sub_dirs(alloc, io, pkg_dirs, "main/default/objects");

        for (objects_dirs) |objects_path| {
            var dir = std.Io.Dir.openDirAbsolute(io, objects_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);

            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                if (entry.kind != .directory) continue;
                const obj_name = try alloc.dupe(u8, entry.name);
                try self.load_object_fields(io, objects_path, obj_name);
            }
        }
    }

    fn load_object_fields(self: *CustomFieldRegistry, io: std.Io, objects_path: []const u8, obj_name: []const u8) !void {
        const alloc = self.arena.allocator();
        const fields_path = try std.fs.path.join(alloc, &.{ objects_path, obj_name, "fields" });

        var fields_dir = std.Io.Dir.openDirAbsolute(io, fields_path, .{ .iterate = true }) catch return;
        defer fields_dir.close(io);

        var fields: std.ArrayList(FieldInfo) = .empty;

        var iter = fields_dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".field-meta.xml")) continue;

            const content = fields_dir.readFileAlloc(io, entry.name, alloc, .limited(64 * 1024)) catch continue;
            const parsed = parse_field_meta_xml(content, alloc) catch continue;
            if (parsed) |field| {
                try fields.append(alloc, field);
            }
        }

        if (fields.items.len > 0) {
            const owned = try fields.toOwnedSlice(alloc);
            try self.objects.put(obj_name, owned);
        }
    }

    pub fn get_fields(self: *const CustomFieldRegistry, type_name: []const u8) ?[]const FieldInfo {
        // 完全一致
        if (self.objects.get(type_name)) |fields| return fields;
        // 大文字小文字を無視してサーチ
        var it = self.objects.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, type_name)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    pub fn is_s_object(self: *const CustomFieldRegistry, type_name: []const u8) bool {
        return self.get_fields(type_name) != null;
    }
};

/// .field-meta.xml (個別フィールドファイル) から 1 フィールドを抽出する。
fn parse_field_meta_xml(content: []const u8, allocator: std.mem.Allocator) !?FieldInfo {
    const name = extract_tag(content, "fullName") orelse return null;
    const field_type = extract_tag(content, "type");
    return .{
        .name = try allocator.dupe(u8, name),
        .type_name = map_sf_field_type(field_type),
    };
}

/// 型名から SObject フィールド一覧を取得する。
pub fn get_fields(type_name: []const u8) ?[]const FieldInfo {
    // ビルトイン検索
    for (&builtin_schemas) |schema| {
        if (std.ascii.eqlIgnoreCase(schema.name, type_name)) {
            return schema.fields;
        }
    }
    return null;
}

/// 型名が既知の SObject かどうか。
pub fn is_s_object(type_name: []const u8) bool {
    return get_fields(type_name) != null;
}

/// .object-meta.xml からカスタムフィールドをパースする。
/// 簡易 XML パーサー: <fullName>FieldName__c</fullName> と <type>Text</type> を抽出。
pub fn parse_object_meta_xml(content: []const u8, allocator: std.mem.Allocator) ![]FieldInfo {
    var fields: std.ArrayList(FieldInfo) = .empty;

    // <fields> ブロックから fullName と type を抽出
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, "<fields>")) |fields_start| {
        const fields_end = std.mem.indexOfPos(u8, content, fields_start, "</fields>") orelse break;
        const block = content[fields_start..fields_end];

        const name = extract_tag(block, "fullName");
        const field_type = extract_tag(block, "type");

        if (name) |n| {
            const name_copy = try allocator.dupe(u8, n);
            const type_str = map_sf_field_type(field_type);
            try fields.append(allocator, .{
                .name = name_copy,
                .type_name = type_str,
            });
        }

        pos = fields_end + "</fields>".len;
    }

    return fields.toOwnedSlice(allocator);
}

fn extract_tag(block: []const u8, tag: []const u8) ?[]const u8 {
    const open_start = std.mem.indexOf(u8, block, "<") orelse return null;
    _ = open_start;
    // <tag>value</tag> を探す
    var buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&buf, "<{s}>", .{tag}) catch return null;
    const start = std.mem.indexOf(u8, block, open) orelse return null;
    const value_start = start + open.len;

    var close_buf: [64]u8 = undefined;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const end = std.mem.indexOfPos(u8, block, value_start, close) orelse return null;

    return block[value_start..end];
}

fn map_sf_field_type(sf_type: ?[]const u8) []const u8 {
    const t = sf_type orelse return "String";
    if (std.ascii.eqlIgnoreCase(t, "Text") or std.ascii.eqlIgnoreCase(t, "TextArea") or std.ascii.eqlIgnoreCase(t, "LongTextArea") or std.ascii.eqlIgnoreCase(t, "RichTextArea") or std.ascii.eqlIgnoreCase(t, "Email") or std.ascii.eqlIgnoreCase(t, "Phone") or std.ascii.eqlIgnoreCase(t, "Url") or std.ascii.eqlIgnoreCase(t, "Picklist") or std.ascii.eqlIgnoreCase(t, "MultiselectPicklist")) return "String";
    if (std.ascii.eqlIgnoreCase(t, "Number") or std.ascii.eqlIgnoreCase(t, "Currency") or std.ascii.eqlIgnoreCase(t, "Percent")) return "Decimal";
    if (std.ascii.eqlIgnoreCase(t, "Checkbox")) return "Boolean";
    if (std.ascii.eqlIgnoreCase(t, "Date")) return "Date";
    if (std.ascii.eqlIgnoreCase(t, "DateTime")) return "Datetime";
    if (std.ascii.eqlIgnoreCase(t, "Lookup") or std.ascii.eqlIgnoreCase(t, "MasterDetail")) return "Id";
    return "String";
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "Account has standard fields" {
    const fields = get_fields("Account");
    try std.testing.expect(fields != null);

    var has_id = false;
    var has_name = false;
    var has_phone = false;
    for (fields.?) |f| {
        if (std.mem.eql(u8, f.name, "Id")) has_id = true;
        if (std.mem.eql(u8, f.name, "Name")) has_name = true;
        if (std.mem.eql(u8, f.name, "Phone")) has_phone = true;
    }
    try std.testing.expect(has_id);
    try std.testing.expect(has_name);
    try std.testing.expect(has_phone);
}

test "Contact has LastName field" {
    const fields = get_fields("Contact");
    try std.testing.expect(fields != null);
    var has_last = false;
    for (fields.?) |f| {
        if (std.mem.eql(u8, f.name, "LastName")) has_last = true;
    }
    try std.testing.expect(has_last);
}

test "case-insensitive lookup" {
    try std.testing.expect(get_fields("account") != null);
    try std.testing.expect(get_fields("ACCOUNT") != null);
}

test "unknown type returns null" {
    try std.testing.expect(get_fields("NonExistent") == null);
}

test "is_s_object" {
    try std.testing.expect(is_s_object("Account"));
    try std.testing.expect(is_s_object("Contact"));
    try std.testing.expect(!is_s_object("String"));
    try std.testing.expect(!is_s_object("Integer"));
}

test "parse_object_meta_xml extracts custom fields" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomObject>
        \\    <fields>
        \\        <fullName>MyField__c</fullName>
        \\        <type>Text</type>
        \\    </fields>
        \\    <fields>
        \\        <fullName>Amount__c</fullName>
        \\        <type>Currency</type>
        \\    </fields>
        \\</CustomObject>
    ;
    const fields = try parse_object_meta_xml(xml, std.testing.allocator);
    defer {
        for (fields) |f| std.testing.allocator.free(f.name);
        std.testing.allocator.free(fields);
    }

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("MyField__c", fields[0].name);
    try std.testing.expectEqualStrings("String", fields[0].type_name);
    try std.testing.expectEqualStrings("Amount__c", fields[1].name);
    try std.testing.expectEqualStrings("Decimal", fields[1].type_name);
}

test "parse_field_meta_xml extracts single field" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\  <fullName>ExternalId__c</fullName>
        \\  <type>Text</type>
        \\  <length>18</length>
        \\</CustomField>
    ;
    const field = try parse_field_meta_xml(xml, std.testing.allocator);
    try std.testing.expect(field != null);
    try std.testing.expectEqualStrings("ExternalId__c", field.?.name);
    try std.testing.expectEqualStrings("String", field.?.type_name);
    std.testing.allocator.free(field.?.name);
}

test "parse_field_meta_xml returns null for missing fullName" {
    const xml =
        \\<CustomField>
        \\  <type>Text</type>
        \\</CustomField>
    ;
    const field = try parse_field_meta_xml(xml, std.testing.allocator);
    try std.testing.expect(field == null);
}

test "CustomFieldRegistry get_fields and is_s_object" {
    var registry = CustomFieldRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const alloc = registry.arena.allocator();
    const fields = try alloc.alloc(FieldInfo, 1);
    fields[0] = .{ .name = "MyField__c", .type_name = "String" };
    try registry.objects.put(try alloc.dupe(u8, "MyCustom__c"), fields);

    try std.testing.expect(registry.get_fields("MyCustom__c") != null);
    try std.testing.expectEqual(@as(usize, 1), registry.get_fields("MyCustom__c").?.len);
    try std.testing.expect(registry.is_s_object("MyCustom__c"));
    try std.testing.expect(!registry.is_s_object("NonExistent__c"));
}
