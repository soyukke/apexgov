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

/// 型名から SObject フィールド一覧を取得する。
pub fn getFields(type_name: []const u8) ?[]const FieldInfo {
    // ビルトイン検索
    for (&builtin_schemas) |schema| {
        if (std.ascii.eqlIgnoreCase(schema.name, type_name)) {
            return schema.fields;
        }
    }
    return null;
}

/// 型名が既知の SObject かどうか。
pub fn isSObject(type_name: []const u8) bool {
    return getFields(type_name) != null;
}

/// .object-meta.xml からカスタムフィールドをパースする。
/// 簡易 XML パーサー: <fullName>FieldName__c</fullName> と <type>Text</type> を抽出。
pub fn parseObjectMetaXml(content: []const u8, allocator: std.mem.Allocator) ![]FieldInfo {
    var fields: std.ArrayList(FieldInfo) = .empty;

    // <fields> ブロックから fullName と type を抽出
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, "<fields>")) |fields_start| {
        const fields_end = std.mem.indexOfPos(u8, content, fields_start, "</fields>") orelse break;
        const block = content[fields_start..fields_end];

        const name = extractTag(block, "fullName");
        const field_type = extractTag(block, "type");

        if (name) |n| {
            const name_copy = try allocator.dupe(u8, n);
            const type_str = mapSfFieldType(field_type);
            try fields.append(allocator, .{
                .name = name_copy,
                .type_name = type_str,
            });
        }

        pos = fields_end + "</fields>".len;
    }

    return fields.toOwnedSlice(allocator);
}

fn extractTag(block: []const u8, tag: []const u8) ?[]const u8 {
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

fn mapSfFieldType(sf_type: ?[]const u8) []const u8 {
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
    const fields = getFields("Account");
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
    const fields = getFields("Contact");
    try std.testing.expect(fields != null);
    var has_last = false;
    for (fields.?) |f| {
        if (std.mem.eql(u8, f.name, "LastName")) has_last = true;
    }
    try std.testing.expect(has_last);
}

test "case-insensitive lookup" {
    try std.testing.expect(getFields("account") != null);
    try std.testing.expect(getFields("ACCOUNT") != null);
}

test "unknown type returns null" {
    try std.testing.expect(getFields("NonExistent") == null);
}

test "isSObject" {
    try std.testing.expect(isSObject("Account"));
    try std.testing.expect(isSObject("Contact"));
    try std.testing.expect(!isSObject("String"));
    try std.testing.expect(!isSObject("Integer"));
}

test "parseObjectMetaXml extracts custom fields" {
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
    const fields = try parseObjectMetaXml(xml, std.testing.allocator);
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
