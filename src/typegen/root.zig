//! typegen — SFDX メタデータから LWC 用 TypeScript 型定義を生成する。
//!
//! `apexgov typegen <sfdx-project-root> [--out DIR]` で以下を生成:
//!   - @salesforce/schema/Object.Field   (field-meta.xml から)
//!   - @salesforce/label/c.XXX           (CustomLabels.labels-meta.xml から)
//!   - @salesforce/resourceUrl/XXX       (*.resource-meta.xml から)
//!   - @salesforce/messageChannel/XXX    (*.messageChannel-meta.xml から)
//!   - @salesforce/apex/Class.method     (.cls の @AuraEnabled から)

const std = @import("std");

// ---------------------------------------------------------------------------
// 簡易 XML タグ値抽出
// ---------------------------------------------------------------------------

/// XML テキストから `<tag>value</tag>` の value を抽出する。
/// ネストなし・属性なしの単純タグのみ対応。
pub fn xmlTagValue(xml: []const u8, tag: []const u8) ?[]const u8 {
    // <tag> を探す
    const open_tag_start = std.mem.indexOf(u8, xml, "<") orelse return null;
    _ = open_tag_start;

    // パターン: "<tag>" と "</tag>" で囲まれた部分
    var pos: usize = 0;
    while (pos < xml.len) {
        const open_start = std.mem.indexOfPos(u8, xml, pos, "<") orelse return null;
        const open_end = std.mem.indexOfPos(u8, xml, open_start, ">") orelse return null;

        const tag_content = xml[open_start + 1 .. open_end];
        // 属性付きタグの場合、タグ名だけ比較
        const tag_name = if (std.mem.indexOfScalar(u8, tag_content, ' ')) |sp|
            tag_content[0..sp]
        else
            tag_content;

        if (std.mem.eql(u8, tag_name, tag)) {
            // 閉じタグを探す
            const value_start = open_end + 1;
            var close_pattern_buf: [128]u8 = undefined;
            const close_pattern = std.fmt.bufPrint(&close_pattern_buf, "</{s}>", .{tag}) catch return null;
            const close_start = std.mem.indexOfPos(u8, xml, value_start, close_pattern) orelse return null;
            const value = std.mem.trim(u8, xml[value_start..close_start], " \t\r\n");
            return value;
        }
        pos = open_end + 1;
    }
    return null;
}

/// XML テキストから `<tag>value</tag>` を全て抽出する（複数マッチ対応）。
pub fn xmlTagValues(xml: []const u8, tag: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;

    var close_pattern_buf: [128]u8 = undefined;
    const close_pattern = std.fmt.bufPrint(&close_pattern_buf, "</{s}>", .{tag}) catch return results.toOwnedSlice(allocator);

    while (pos < xml.len) {
        const open_start = std.mem.indexOfPos(u8, xml, pos, "<") orelse break;
        const open_end = std.mem.indexOfPos(u8, xml, open_start, ">") orelse break;

        const tag_content = xml[open_start + 1 .. open_end];
        const tag_name = if (std.mem.indexOfScalar(u8, tag_content, ' ')) |sp|
            tag_content[0..sp]
        else
            tag_content;

        if (std.mem.eql(u8, tag_name, tag)) {
            const value_start = open_end + 1;
            const close_start = std.mem.indexOfPos(u8, xml, value_start, close_pattern) orelse break;
            const value = std.mem.trim(u8, xml[value_start..close_start], " \t\r\n");
            try results.append(allocator, value);
            pos = close_start + close_pattern.len;
        } else {
            pos = open_end + 1;
        }
    }
    return results.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// フィールド型 → TypeScript 型マッピング
// ---------------------------------------------------------------------------

/// Salesforce フィールド型名を TypeScript 型に変換する。
pub fn sfTypeToTs(sf_type: []const u8) []const u8 {
    // 数値系
    if (eqlAny(sf_type, &.{ "Number", "Currency", "Percent", "Double", "Int", "Long" })) return "number";
    // 真偽値
    if (std.mem.eql(u8, sf_type, "Checkbox")) return "boolean";
    // それ以外は string（Text, LongTextArea, RichTextArea, Phone, Email, Url,
    // Date, DateTime, Time, Picklist, MultiselectPicklist, Lookup, MasterDetail, Id, etc.）
    if (eqlAny(sf_type, &.{
        "Text",                 "LongTextArea", "RichTextArea",  "Html",
        "Phone",                "Email",        "Url",           "TextArea",
        "Date",                 "DateTime",     "Time",          "Picklist",
        "MultiselectPicklist",  "Lookup",       "MasterDetail",  "ExternalLookup",
        "MetadataRelationship", "AutoNumber",   "EncryptedText",
    })) return "string";
    return "any";
}

fn eqlAny(s: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, s, c)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// @salesforce/schema 型定義生成
// ---------------------------------------------------------------------------

pub const SchemaField = struct {
    object_name: []const u8,
    field_name: []const u8,
    ts_type: []const u8,
};

/// field-meta.xml の内容からフィールド情報を抽出する。
pub fn parseFieldMeta(xml: []const u8, object_name: []const u8) ?SchemaField {
    const full_name = xmlTagValue(xml, "fullName") orelse return null;
    const sf_type = xmlTagValue(xml, "type") orelse "Text";
    return .{
        .object_name = object_name,
        .field_name = full_name,
        .ts_type = sfTypeToTs(sf_type),
    };
}

/// SchemaField から TypeScript 型定義文字列を生成する。
pub fn renderSchemaField(field: SchemaField, writer: anytype) !void {
    try writer.print(
        \\declare module "@salesforce/schema/{s}.{s}" {{
        \\    const {s}: {s};
        \\    export default {s};
        \\}}
        \\
    , .{ field.object_name, field.field_name, field.field_name, field.ts_type, field.field_name });
}

// ---------------------------------------------------------------------------
// @salesforce/label 型定義生成
// ---------------------------------------------------------------------------

/// CustomLabels.labels-meta.xml からラベル名を全て抽出する。
pub fn parseLabelNames(xml: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    return xmlTagValues(xml, "fullName", allocator);
}

/// ラベル名から TypeScript 型定義を生成する。
pub fn renderLabel(label_name: []const u8, writer: anytype) !void {
    try writer.print(
        \\declare module "@salesforce/label/c.{s}" {{
        \\    var {s}: string;
        \\    export default {s};
        \\}}
    , .{ label_name, label_name, label_name });
}

// ---------------------------------------------------------------------------
// @salesforce/resourceUrl 型定義生成
// ---------------------------------------------------------------------------

/// リソース名から TypeScript 型定義を生成する。
pub fn renderResourceUrl(resource_name: []const u8, writer: anytype) !void {
    try writer.print(
        \\declare module "@salesforce/resourceUrl/{s}" {{
        \\    var {s}: string;
        \\    export default {s};
        \\}}
    , .{ resource_name, resource_name, resource_name });
}

// ---------------------------------------------------------------------------
// @salesforce/messageChannel 型定義生成
// ---------------------------------------------------------------------------

/// メッセージチャネル名から TypeScript 型定義を生成する。
/// 公式 LWC LS と同様、モジュールパスに __c サフィックスを付与する。
pub fn renderMessageChannel(channel_name: []const u8, writer: anytype) !void {
    try writer.print(
        \\declare module "@salesforce/messageChannel/{s}__c" {{
        \\    var {s}: string;
        \\    export default {s};
        \\}}
    , .{ channel_name, channel_name, channel_name });
}

// ---------------------------------------------------------------------------
// @salesforce/contentAssetUrl 型定義生成
// ---------------------------------------------------------------------------

/// コンテンツアセット名から TypeScript 型定義を生成する。
pub fn renderContentAssetUrl(asset_name: []const u8, writer: anytype) !void {
    try writer.print(
        \\declare module "@salesforce/contentAssetUrl/{s}" {{
        \\    var {s}: string;
        \\    export default {s};
        \\}}
    , .{ asset_name, asset_name, asset_name });
}

// ---------------------------------------------------------------------------
// @salesforce/apex 型定義生成
// ---------------------------------------------------------------------------

pub const ApexMethod = struct {
    class_name: []const u8,
    method_name: []const u8,
};

/// Apex ソースコードから @AuraEnabled public/global static メソッドを検出する。
pub fn findAuraEnabledMethods(source: []const u8, class_name: []const u8, allocator: std.mem.Allocator) ![]ApexMethod {
    var methods: std.ArrayList(ApexMethod) = .empty;
    var pos: usize = 0;

    while (pos < source.len) {
        // @AuraEnabled を探す
        const aura_pos = std.ascii.indexOfIgnoreCasePos(source, pos, "@AuraEnabled") orelse break;
        // @AuraEnabled の後ろから public/global static メソッドを探す
        const search_start = aura_pos + "@AuraEnabled".len;

        // メソッドシグネチャまでの範囲（次の { か ; まで）
        const sig_end = blk: {
            var i = search_start;
            var paren_depth: u32 = 0;
            while (i < source.len) : (i += 1) {
                if (source[i] == '(') paren_depth += 1;
                if (source[i] == ')') {
                    if (paren_depth > 0) paren_depth -= 1;
                    // AuraEnabled(...) のパラメータを閉じた後に続ける
                }
                if (paren_depth == 0 and (source[i] == '{' or source[i] == ';')) break :blk i;
            }
            break :blk source.len;
        };

        const sig = source[search_start..sig_end];

        // "static" が含まれているか確認
        if (std.ascii.indexOfIgnoreCase(sig, "static") != null) {
            // メソッド名を抽出: 最後の "identifier(" パターンを探す
            if (extractMethodName(sig)) |method_name| {
                try methods.append(allocator, .{
                    .class_name = class_name,
                    .method_name = method_name,
                });
            }
        }

        pos = sig_end;
    }
    return methods.toOwnedSlice(allocator);
}

fn extractMethodName(sig: []const u8) ?[]const u8 {
    // 最後の '(' の直前にある識別子がメソッド名
    const paren_pos = std.mem.lastIndexOfScalar(u8, sig, '(') orelse return null;
    // '(' の前の空白をスキップ
    var end = paren_pos;
    while (end > 0 and sig[end - 1] == ' ') end -= 1;
    if (end == 0) return null;
    // 識別子の先頭を探す
    var start = end;
    while (start > 0 and isIdentChar(sig[start - 1])) start -= 1;
    if (start == end) return null;
    return sig[start..end];
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// ApexMethod から TypeScript 型定義を生成する。
pub fn renderApexMethod(method: ApexMethod, writer: anytype) !void {
    try writer.print(
        \\declare module "@salesforce/apex/{s}.{s}" {{
        \\    export default function {s}(params?: any): Promise<any>;
        \\}}
        \\
    , .{ method.class_name, method.method_name, method.method_name });
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "xmlTagValue extracts simple tag" {
    const xml = "<type>Number</type>";
    try std.testing.expectEqualStrings("Number", xmlTagValue(xml, "type").?);
}

test "xmlTagValue extracts from full field-meta.xml" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Amount__c</fullName>
        \\    <type>Currency</type>
        \\</CustomField>
    ;
    try std.testing.expectEqualStrings("Amount__c", xmlTagValue(xml, "fullName").?);
    try std.testing.expectEqualStrings("Currency", xmlTagValue(xml, "type").?);
}

test "xmlTagValue returns null for missing tag" {
    const xml = "<type>Number</type>";
    try std.testing.expect(xmlTagValue(xml, "missing") == null);
}

test "xmlTagValues extracts multiple labels" {
    const xml =
        \\<CustomLabels>
        \\    <labels><fullName>Label1</fullName></labels>
        \\    <labels><fullName>Label2</fullName></labels>
        \\</CustomLabels>
    ;
    const names = try xmlTagValues(xml, "fullName", std.testing.allocator);
    defer std.testing.allocator.free(names);

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("Label1", names[0]);
    try std.testing.expectEqualStrings("Label2", names[1]);
}

test "sfTypeToTs maps correctly" {
    try std.testing.expectEqualStrings("number", sfTypeToTs("Number"));
    try std.testing.expectEqualStrings("number", sfTypeToTs("Currency"));
    try std.testing.expectEqualStrings("boolean", sfTypeToTs("Checkbox"));
    try std.testing.expectEqualStrings("string", sfTypeToTs("Text"));
    try std.testing.expectEqualStrings("string", sfTypeToTs("Date"));
    try std.testing.expectEqualStrings("string", sfTypeToTs("Lookup"));
    try std.testing.expectEqualStrings("any", sfTypeToTs("SomeUnknownType"));
}

test "parseFieldMeta extracts field info" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Revenue__c</fullName>
        \\    <type>Currency</type>
        \\</CustomField>
    ;
    const field = parseFieldMeta(xml, "Account").?;
    try std.testing.expectEqualStrings("Account", field.object_name);
    try std.testing.expectEqualStrings("Revenue__c", field.field_name);
    try std.testing.expectEqualStrings("number", field.ts_type);
}

test "renderSchemaField generates correct .d.ts" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    try renderSchemaField(.{
        .object_name = "Account",
        .field_name = "Name",
        .ts_type = "string",
    }, &buf.writer);
    const expected =
        \\declare module "@salesforce/schema/Account.Name" {
        \\    const Name: string;
        \\    export default Name;
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, buf.written());
}

test "renderLabel matches official format" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    try renderLabel("Github_username", &buf.writer);
    const expected =
        \\declare module "@salesforce/label/c.Github_username" {
        \\    var Github_username: string;
        \\    export default Github_username;
        \\}
    ;
    try std.testing.expectEqualStrings(expected, buf.written());
}

test "renderResourceUrl matches official format" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    try renderResourceUrl("leafletjs", &buf.writer);
    const expected =
        \\declare module "@salesforce/resourceUrl/leafletjs" {
        \\    var leafletjs: string;
        \\    export default leafletjs;
        \\}
    ;
    try std.testing.expectEqualStrings(expected, buf.written());
}

test "renderMessageChannel adds __c suffix (official format)" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    try renderMessageChannel("PropertySelected", &buf.writer);
    const expected =
        \\declare module "@salesforce/messageChannel/PropertySelected__c" {
        \\    var PropertySelected: string;
        \\    export default PropertySelected;
        \\}
    ;
    try std.testing.expectEqualStrings(expected, buf.written());
}

test "renderContentAssetUrl matches official format" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    try renderContentAssetUrl("dreamhouselogosquare", &buf.writer);
    const expected =
        \\declare module "@salesforce/contentAssetUrl/dreamhouselogosquare" {
        \\    var dreamhouselogosquare: string;
        \\    export default dreamhouselogosquare;
        \\}
    ;
    try std.testing.expectEqualStrings(expected, buf.written());
}

test "findAuraEnabledMethods detects @AuraEnabled static method" {
    const source =
        \\public with sharing class MyController {
        \\    @AuraEnabled(cacheable=true)
        \\    public static List<Account> getAccounts() {
        \\        return [SELECT Id, Name FROM Account];
        \\    }
        \\    public void nonAuraMethod() {}
        \\}
    ;
    const methods = try findAuraEnabledMethods(source, "MyController", std.testing.allocator);
    defer std.testing.allocator.free(methods);

    try std.testing.expectEqual(@as(usize, 1), methods.len);
    try std.testing.expectEqualStrings("MyController", methods[0].class_name);
    try std.testing.expectEqualStrings("getAccounts", methods[0].method_name);
}

test "findAuraEnabledMethods skips non-static @AuraEnabled" {
    const source =
        \\public class Foo {
        \\    @AuraEnabled
        \\    public String name { get; set; }
        \\}
    ;
    const methods = try findAuraEnabledMethods(source, "Foo", std.testing.allocator);
    defer std.testing.allocator.free(methods);

    try std.testing.expectEqual(@as(usize, 0), methods.len);
}

test "findAuraEnabledMethods detects multiple methods" {
    const source =
        \\public class Ctrl {
        \\    @AuraEnabled
        \\    public static String getName() { return 'a'; }
        \\    @AuraEnabled(cacheable=true scope='global')
        \\    public static List<Contact> getContacts(Id accountId) {
        \\        return null;
        \\    }
        \\}
    ;
    const methods = try findAuraEnabledMethods(source, "Ctrl", std.testing.allocator);
    defer std.testing.allocator.free(methods);

    try std.testing.expectEqual(@as(usize, 2), methods.len);
    try std.testing.expectEqualStrings("getName", methods[0].method_name);
    try std.testing.expectEqualStrings("getContacts", methods[1].method_name);
}

test "renderApexMethod generates correct .d.ts" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    try renderApexMethod(.{
        .class_name = "AccountController",
        .method_name = "getAccounts",
    }, &buf.writer);
    const output = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "@salesforce/apex/AccountController.getAccounts") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export default function getAccounts") != null);
}
