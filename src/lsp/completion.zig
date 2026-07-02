//! completion — カーソル位置でのコード補完候補を返す。
//!
//! ドットの後: 型ベースのメンバー補完（SObject フィールド、標準ライブラリメソッド）
//! それ以外: スコープ内シンボル + Apex キーワード

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const sobject_schema = @import("sobject_schema.zig");
const apex_stdlib = @import("apex_stdlib.zig");

/// Apex キーワード一覧。
const apex_keywords = [_][]const u8{
    "abstract",    "break",        "catch",                 "class",               "continue",
    "delete",      "do",           "else",                  "enum",                "extends",
    "final",       "finally",      "for",                   "global",              "if",
    "implements",  "insert",       "interface",             "merge",               "new",
    "null",        "override",     "private",               "protected",           "public",
    "return",      "static",       "super",                 "switch",              "this",
    "throw",       "transient",    "trigger",               "try",                 "undelete",
    "update",      "upsert",       "virtual",               "void",                "when",
    "while",       "with",         "without",
    // 組み込み型
                  "Boolean",             "Date",
    "Datetime",    "Decimal",      "Double",                "Id",                  "Integer",
    "Long",        "Object",       "String",                "Blob",                "Time",
    "List",        "Map",          "Set",                   "Schema",              "SObject",
    "SObjectType", "SObjectField", "DescribeSObjectResult", "DescribeFieldResult", "Type",
};

pub fn get_completions(
    result: *const binder_mod.BindResult,
    source: []const u8,
    offset: u32,
    allocator: std.mem.Allocator,
    custom_fields: ?*const sobject_schema.CustomFieldRegistry,
) ![]lsp_types.CompletionItem {
    // ドット補完の検出: offset の直前が '.' かチェック
    const dot_ctx = detect_dot_context(source, offset, result, custom_fields);
    if (dot_ctx) |type_name| {
        return get_dot_completions(type_name, result, allocator, custom_fields);
    }

    // 通常補完: スコープ内シンボル + キーワード
    return get_default_completions(result, allocator);
}

/// ドットの直前にある変数/型の type_name を解決する。
fn detect_dot_context(
    source: []const u8,
    offset: u32,
    result: *const binder_mod.BindResult,
    custom_fields: ?*const sobject_schema.CustomFieldRegistry,
) ?[]const u8 {
    if (offset == 0) return null;

    // offset の直前（空白をスキップ）に '.' があるか
    var pos: u32 = offset;
    while (pos > 0 and source[pos - 1] == ' ') pos -= 1;
    if (pos == 0 or source[pos - 1] != '.') return null;
    const dot_index = pos - 1;
    if (infer_receiver_type_before_dot(source, dot_index, result, custom_fields)) |t| return t;

    pos -= 1; // '.' をスキップ

    // '.' の前の識別子を逆方向に読む
    while (pos > 0 and source[pos - 1] == ' ') pos -= 1;
    if (pos == 0) return null;

    const name_end = pos;
    while (pos > 0 and (std.ascii.isAlphanumeric(source[pos - 1]) or source[pos - 1] == '_')) {
        pos -= 1;
    }
    if (pos == name_end) return null;
    const receiver_name = source[pos..name_end];

    // 1. 静的クラス名としてマッチ（System.debug 等）
    if (apex_stdlib.is_stdlib_type(receiver_name)) return receiver_name;
    if (sobject_schema.is_s_object(receiver_name)) return receiver_name;
    if (custom_fields) |cf| {
        if (cf.is_s_object(receiver_name)) return receiver_name;
    }

    // 2. binder でシンボル解決 → type_name を取得
    const sym = binder_mod.symbol_at_position(result, pos) orelse {
        // シンボルテーブルにない場合、名前で全シンボルを検索
        for (result.symbols) |*s| {
            if (binder_mod.names_equal(s.name, receiver_name)) {
                return s.type_name;
            }
        }
        return null;
    };
    return sym.type_name;
}

fn infer_receiver_type_before_dot(
    source: []const u8,
    dot_index: u32,
    result: *const binder_mod.BindResult,
    custom_fields: ?*const sobject_schema.CustomFieldRegistry,
) ?[]const u8 {
    var before_dot = dot_index;
    if (before_dot > 0 and source[before_dot - 1] == '?') before_dot -= 1;
    while (before_dot > 0 and source[before_dot - 1] == ' ') before_dot -= 1;
    if (before_dot == 0) return null;

    if (source[before_dot - 1] == ']') {
        const base_name = identifier_before_index_access(source, before_dot) orelse return null;
        const raw_type = infer_variable_type_from_source(source, dot_index, base_name) orelse
            symbol_type_by_name(result, base_name) orelse return null;
        return element_type_from_collection(raw_type);
    }

    const receiver_name = identifier_ending_at(source, before_dot) orelse return null;
    if (apex_stdlib.is_stdlib_type(receiver_name)) return receiver_name;
    if (sobject_schema.is_s_object(receiver_name)) return receiver_name;
    if (custom_fields) |cf| {
        if (cf.is_s_object(receiver_name)) return receiver_name;
    }

    return infer_variable_type_from_source(source, dot_index, receiver_name) orelse
        symbol_type_by_name(result, receiver_name);
}

fn identifier_before_index_access(source: []const u8, end: u32) ?[]const u8 {
    if (end == 0 or source[end - 1] != ']') return null;
    var depth: u32 = 0;
    var i = end;
    while (i > 0) {
        i -= 1;
        if (source[i] == ']') depth += 1;
        if (source[i] == '[') {
            depth -= 1;
            if (depth == 0) return identifier_ending_at(source, @intCast(i));
        }
    }
    return null;
}

fn identifier_ending_at(source: []const u8, end: u32) ?[]const u8 {
    var i = end;
    while (i > 0 and source[i - 1] == ' ') i -= 1;
    const name_end = i;
    while (i > 0 and (std.ascii.isAlphanumeric(source[i - 1]) or source[i - 1] == '_')) {
        i -= 1;
    }
    if (i == name_end) return null;
    return source[i..name_end];
}

fn infer_variable_type_from_source(source: []const u8, offset: u32, name: []const u8) ?[]const u8 {
    var search_end: usize = @min(offset, source.len);
    while (std.mem.lastIndexOf(u8, source[0..search_end], name)) |idx| {
        search_end = idx;
        if (!is_word_boundary(source, idx, name.len)) continue;

        var type_end = idx;
        while (type_end > 0 and std.ascii.isWhitespace(source[type_end - 1])) type_end -= 1;
        const type_start = type_name_start_before(source, type_end);
        const raw_type = std.mem.trim(u8, source[type_start..type_end], " \t\r\n");
        if (raw_type.len > 0) return raw_type;
    }
    return null;
}

fn type_name_start_before(source: []const u8, type_end: usize) usize {
    var type_start = type_end;
    var generic_depth: u32 = 0;
    while (type_start > 0) {
        const c = source[type_start - 1];
        if (c == '>') {
            generic_depth += 1;
        } else if (c == '<') {
            if (generic_depth == 0) break;
            generic_depth -= 1;
        } else if (generic_depth == 0 and
            (c == '(' or c == ',' or c == ';' or c == '{' or c == '=' or c == ':'))
        {
            break;
        } else if (!is_type_name_char(c)) {
            break;
        }
        type_start -= 1;
    }
    return type_start;
}

fn is_word_boundary(source: []const u8, start: usize, len: usize) bool {
    const before_ok = start == 0 or !is_ident_char(source[start - 1]);
    const after = start + len;
    const after_ok = after >= source.len or !is_ident_char(source[after]);
    return before_ok and after_ok;
}

fn is_ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn is_type_name_char(c: u8) bool {
    return is_ident_char(c) or c == '.' or c == '<' or c == '>' or c == ',' or
        c == '[' or c == ']' or std.ascii.isWhitespace(c);
}

fn symbol_type_by_name(result: *const binder_mod.BindResult, name: []const u8) ?[]const u8 {
    for (result.symbols) |*s| {
        if (binder_mod.names_equal(s.name, name)) return s.type_name;
    }
    return null;
}

fn element_type_from_collection(raw_type: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw_type, " \t\r\n");
    if (generic_inner(trimmed, "List")) |inner| return inner;
    if (generic_inner(trimmed, "Set")) |inner| return inner;
    if (std.mem.endsWith(u8, trimmed, "[]")) {
        return std.mem.trim(u8, trimmed[0 .. trimmed.len - 2], " \t");
    }
    return null;
}

fn generic_inner(type_name: []const u8, base_name: []const u8) ?[]const u8 {
    const compact = std.mem.trim(u8, type_name, " \t\r\n");
    if (!std.mem.startsWith(u8, compact, base_name)) return null;
    var i = base_name.len;
    while (i < compact.len and std.ascii.isWhitespace(compact[i])) i += 1;
    if (i >= compact.len or compact[i] != '<' or compact[compact.len - 1] != '>') return null;
    return std.mem.trim(u8, compact[i + 1 .. compact.len - 1], " \t");
}

fn base_type_name(type_name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");
    if (std.mem.indexOfScalar(u8, trimmed, '<')) |idx| {
        return std.mem.trim(u8, trimmed[0..idx], " \t");
    }
    if (std.mem.endsWith(u8, trimmed, "[]")) {
        return std.mem.trim(u8, trimmed[0 .. trimmed.len - 2], " \t");
    }
    return trimmed;
}

/// 型ベースのドット補完。SObject フィールド + 標準ライブラリメソッド。
fn get_dot_completions(
    type_name: []const u8,
    result: *const binder_mod.BindResult,
    allocator: std.mem.Allocator,
    custom_fields: ?*const sobject_schema.CustomFieldRegistry,
) ![]lsp_types.CompletionItem {
    var items: std.ArrayList(lsp_types.CompletionItem) = .empty;
    const resolved_type = base_type_name(type_name);

    try append_standard_sobject_fields(&items, allocator, resolved_type);
    try append_custom_sobject_fields(&items, allocator, resolved_type, custom_fields);
    try append_sobject_type_tokens(&items, allocator, resolved_type, custom_fields);
    try append_stdlib_members(&items, allocator, resolved_type);
    try append_user_class_members(&items, allocator, resolved_type, result);

    return items.toOwnedSlice(allocator);
}

fn append_standard_sobject_fields(
    items: *std.ArrayList(lsp_types.CompletionItem),
    allocator: std.mem.Allocator,
    resolved_type: []const u8,
) !void {
    if (sobject_schema.get_fields(resolved_type)) |fields| {
        for (fields) |f| {
            try items.append(allocator, .{
                .label = f.name,
                .kind = .field,
                .detail = f.type_name,
            });
        }
    }
}

fn append_custom_sobject_fields(
    items: *std.ArrayList(lsp_types.CompletionItem),
    allocator: std.mem.Allocator,
    resolved_type: []const u8,
    custom_fields: ?*const sobject_schema.CustomFieldRegistry,
) !void {
    if (custom_fields) |cf| {
        if (cf.get_fields(resolved_type)) |fields| {
            for (fields) |f| {
                try items.append(allocator, .{
                    .label = f.name,
                    .kind = .field,
                    .detail = f.type_name,
                });
            }
        }
    }
}

fn append_sobject_type_tokens(
    items: *std.ArrayList(lsp_types.CompletionItem),
    allocator: std.mem.Allocator,
    resolved_type: []const u8,
    custom_fields: ?*const sobject_schema.CustomFieldRegistry,
) !void {
    if (is_sobject_type_name(resolved_type, custom_fields)) {
        try items.append(allocator, .{
            .label = "getSObjectType",
            .kind = .method,
            .detail = "Schema.SObjectType getSObjectType()",
        });
        try items.append(allocator, .{
            .label = "SObjectType",
            .kind = .field,
            .detail = "Schema.SObjectType SObjectType",
        });
        try items.append(allocator, .{
            .label = "sObjectType",
            .kind = .field,
            .detail = "Schema.SObjectType sObjectType",
        });
    }
}

fn append_stdlib_members(
    items: *std.ArrayList(lsp_types.CompletionItem),
    allocator: std.mem.Allocator,
    resolved_type: []const u8,
) !void {
    if (apex_stdlib.get_members(resolved_type)) |members| {
        for (members) |m| {
            try items.append(allocator, .{
                .label = m.name,
                .kind = if (m.kind == .method) .method else .field,
                .detail = m.detail,
            });
        }
    }
}

fn append_user_class_members(
    items: *std.ArrayList(lsp_types.CompletionItem),
    allocator: std.mem.Allocator,
    resolved_type: []const u8,
    result: *const binder_mod.BindResult,
) !void {
    for (result.symbols) |sym| {
        if (sym.parent) |parent_id| {
            if (parent_id < result.symbols.len) {
                const parent = &result.symbols[parent_id];
                if (parent.kind == .class and binder_mod.names_equal(parent.name, resolved_type)) {
                    const kind: lsp_types.CompletionItemKind = switch (sym.kind) {
                        .method => .method,
                        .field => .field,
                        .constructor => .constructor,
                        else => .variable,
                    };
                    try items.append(allocator, .{
                        .label = sym.name,
                        .kind = kind,
                        .detail = sym.type_name,
                    });
                }
            }
        }
    }
}

fn is_sobject_type_name(
    type_name: []const u8,
    custom_fields: ?*const sobject_schema.CustomFieldRegistry,
) bool {
    if (std.ascii.eqlIgnoreCase(type_name, "SObject")) return false;
    if (sobject_schema.is_s_object(type_name)) return true;
    if (custom_fields) |cf| return cf.is_s_object(type_name);
    return false;
}

/// 通常補完: スコープ内シンボル + キーワード。
fn get_default_completions(
    result: *const binder_mod.BindResult,
    allocator: std.mem.Allocator,
) ![]lsp_types.CompletionItem {
    var items: std.ArrayList(lsp_types.CompletionItem) = .empty;

    for (result.symbols) |sym| {
        const kind: lsp_types.CompletionItemKind = switch (sym.kind) {
            .class => .class,
            .interface => .interface,
            .enum_type => .@"enum",
            .enum_value => .enum_member,
            .method => .method,
            .constructor => .constructor,
            .field => .field,
            .parameter, .local_variable, .for_each_variable, .catch_variable => .variable,
            .trigger => .class,
        };
        try items.append(allocator, .{
            .label = sym.name,
            .kind = kind,
            .detail = sym.type_name,
        });
    }

    for (&apex_keywords) |kw| {
        try items.append(allocator, .{
            .label = kw,
            .kind = .keyword,
        });
    }

    return items.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

const TestComplCtx = struct {
    items: []lsp_types.CompletionItem,
    arena: std.heap.ArenaAllocator,
    fn deinit(self: *TestComplCtx) void {
        self.arena.deinit();
    }
};

fn complete_at(source: []const u8, offset: u32) !TestComplCtx {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const alloc = arena.allocator();
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);
    const items = try get_completions(&br, source, offset, alloc, null);
    return .{ .items = items, .arena = arena };
}

fn has_label(items: []const lsp_types.CompletionItem, label: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return true;
    }
    return false;
}

fn has_label_with_kind(
    items: []const lsp_types.CompletionItem,
    label: []const u8,
    kind: lsp_types.CompletionItemKind,
) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label) and
            item.kind != null and item.kind.? == kind) return true;
    }
    return false;
}

// -- 既存テスト --

test "local variables in completions" {
    const source = "public class Foo { public void run() { Integer myVar = 1; } }";
    var ctx = try complete_at(source, 50);
    defer ctx.deinit();

    try std.testing.expect(has_label(ctx.items, "myVar"));
}

test "keywords in completions" {
    const source = "public class Foo {}";
    var ctx = try complete_at(source, 10);
    defer ctx.deinit();

    try std.testing.expect(has_label(ctx.items, "public"));
    try std.testing.expect(has_label(ctx.items, "class"));
    try std.testing.expect(has_label(ctx.items, "String"));
    try std.testing.expect(has_label(ctx.items, "Type"));
}

test "method parameters visible" {
    const source = "public class Foo { public void run(String name) {} }";
    var ctx = try complete_at(source, 45);
    defer ctx.deinit();

    try std.testing.expect(has_label(ctx.items, "name"));
}

// -- ドット補完テスト --

test "dot completion: Account fields after acc." {
    // "acc." のドットの直後が offset
    const source = "public class Foo { public void run() { Account acc; acc. } }";
    const dot_pos = std.mem.indexOf(u8, source, "acc. ").? + 4; // "acc." の直後
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "Id", .field));
    try std.testing.expect(has_label_with_kind(ctx.items, "Name", .field));
    try std.testing.expect(has_label_with_kind(ctx.items, "Phone", .field));
    // キーワードは含まれない
    try std.testing.expect(!has_label(ctx.items, "public"));
}

test "dot completion: String methods after str." {
    const source = "public class Foo { public void run() { String str; str. } }";
    const dot_pos = std.mem.indexOf(u8, source, "str. ").? + 4;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "length", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "toLowerCase", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "contains", .method));
}

test "dot completion: variable receiver is case-insensitive" {
    const source = "public class Foo { public void run() { String Value; value. } }";
    const dot_pos = std.mem.indexOf(u8, source, "value. ").? + "value.".len;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "length", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "toLowerCase", .method));
}

test "dot completion: System.debug static access" {
    const source = "public class Foo { public void run() { System. } }";
    const dot_pos = std.mem.indexOf(u8, source, "System. ").? + 7;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "debug", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "assertEquals", .method));
}

test "dot completion: Type.forName static access" {
    const source = "public class Foo { public void run() { Type. } }";
    const dot_pos = std.mem.indexOf(u8, source, "Type. ").? + 5;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "forName", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "newInstance", .method));
}

test "dot completion: Type variable methods" {
    const source =
        \\public class Foo {
        \\    public void run(String objType) {
        \\        Type dynamicMapType = Type.forName('Map<Id,' + objType + '>');
        \\        dynamicMapType.
        \\    }
        \\}
    ;
    const dot_pos = std.mem.indexOf(u8, source, "dynamicMapType.").? + "dynamicMapType.".len;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "getName", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "newInstance", .method));
}

test "dot completion: SObject methods after for-each variable" {
    const source =
        \\public class Foo {
        \\    public void run(List<SObject> incomingList) {
        \\        for (SObject current : incomingList) {
        \\            current.
        \\        }
        \\    }
        \\}
    ;
    const dot_pos = std.mem.indexOf(u8, source, "current.").? + "current.".len;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "get", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "put", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "getSObjectType", .method));
}

test "dot completion: SObject methods after list index null-safe access" {
    const source =
        \\public class Foo {
        \\    public void run(String key, List<SObject> incomingList) {
        \\        incomingList[0]?.
        \\    }
        \\}
    ;
    const dot_pos = std.mem.indexOf(u8, source, "incomingList[0]?.").? + "incomingList[0]?.".len;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "getSObjectType", .method));
}

test "dot completion: Id methods after record id" {
    const source = "public class Foo { public void run() { Id recordId; recordId. } }";
    const dot_pos = std.mem.indexOf(u8, source, "recordId. ").? + "recordId.".len;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "getSObjectType", .method));
}

test "dot completion: List of SObject exposes getSObjectType" {
    const source = "public class Foo { public void run() { List<SObject> records; records. } }";
    const dot_pos = std.mem.indexOf(u8, source, "records. ").? + "records.".len;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "getSObjectType", .method));
}

test "dot completion: SObject type token methods after object type" {
    const source = "public class Foo { public void run() { Account. } }";
    const dot_pos = std.mem.indexOf(u8, source, "Account. ").? + "Account.".len;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "getSObjectType", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "SObjectType", .field));
}

test "dot completion: Schema namespace methods" {
    const source = "public class Foo { public void run() { Schema. } }";
    const dot_pos = std.mem.indexOf(u8, source, "Schema. ").? + "Schema.".len;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "getGlobalDescribe", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "describeSObjects", .method));
}

test "dot completion: Schema.SObjectType variable methods" {
    const source =
        \\public class Foo {
        \\    public void run() {
        \\        Schema.SObjectType token;
        \\        token.
        \\    }
        \\}
    ;
    const dot_pos = std.mem.indexOf(u8, source, "token.").? + "token.".len;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "getDescribe", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "newSObject", .method));
}

test "dot completion: List methods after list." {
    const source = "public class Foo { public void run() { List items; items. } }";
    const dot_pos = std.mem.indexOf(u8, source, "items. ").? + 6;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "add", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "size", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "isEmpty", .method));
    try std.testing.expect(has_label_with_kind(ctx.items, "getSObjectType", .method));
}

test "dot completion: Contact fields" {
    const source = "public class Foo { public void run() { Contact c; c. } }";
    const dot_pos = std.mem.indexOf(u8, source, "c. ").? + 2;
    var ctx = try complete_at(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(has_label_with_kind(ctx.items, "FirstName", .field));
    try std.testing.expect(has_label_with_kind(ctx.items, "LastName", .field));
    try std.testing.expect(has_label_with_kind(ctx.items, "Email", .field));
}

test "no dot: returns keywords and symbols, not SObject fields" {
    const source = "public class Foo { public void run() { Account acc; } }";
    var ctx = try complete_at(source, 50);
    defer ctx.deinit();

    try std.testing.expect(has_label(ctx.items, "acc"));
    try std.testing.expect(has_label(ctx.items, "public"));
    // SObject フィールドは含まれない
    try std.testing.expect(!has_label(ctx.items, "Phone"));
}
