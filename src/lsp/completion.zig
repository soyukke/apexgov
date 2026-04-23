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
    "abstract",   "break",     "catch",     "class",     "continue",
    "delete",     "do",        "else",      "enum",      "extends",
    "final",      "finally",   "for",       "global",    "if",
    "implements", "insert",    "interface", "merge",     "new",
    "null",       "override",  "private",   "protected", "public",
    "return",     "static",    "super",     "switch",    "this",
    "throw",      "transient", "trigger",   "try",       "undelete",
    "update",     "upsert",    "virtual",   "void",      "when",
    "while",      "with",      "without",
    // 組み込み型
      "Boolean",   "Date",
    "Datetime",   "Decimal",   "Double",    "Id",        "Integer",
    "Long",       "Object",    "String",    "Blob",      "Time",
    "List",       "Map",       "Set",
};

pub fn getCompletions(
    result: *const binder_mod.BindResult,
    source: []const u8,
    offset: u32,
    allocator: std.mem.Allocator,
    custom_fields: ?*const sobject_schema.CustomFieldRegistry,
) ![]lsp_types.CompletionItem {
    // ドット補完の検出: offset の直前が '.' かチェック
    const dot_ctx = detectDotContext(source, offset, result, custom_fields);
    if (dot_ctx) |type_name| {
        return getDotCompletions(type_name, result, allocator, custom_fields);
    }

    // 通常補完: スコープ内シンボル + キーワード
    return getDefaultCompletions(result, allocator);
}

/// ドットの直前にある変数/型の type_name を解決する。
fn detectDotContext(source: []const u8, offset: u32, result: *const binder_mod.BindResult, custom_fields: ?*const sobject_schema.CustomFieldRegistry) ?[]const u8 {
    if (offset == 0) return null;

    // offset の直前（空白をスキップ）に '.' があるか
    var pos: u32 = offset;
    while (pos > 0 and source[pos - 1] == ' ') pos -= 1;
    if (pos == 0 or source[pos - 1] != '.') return null;
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
    if (apex_stdlib.isStdlibType(receiver_name)) return receiver_name;
    if (sobject_schema.isSObject(receiver_name)) return receiver_name;
    if (custom_fields) |cf| {
        if (cf.isSObject(receiver_name)) return receiver_name;
    }

    // 2. binder でシンボル解決 → type_name を取得
    const sym = binder_mod.symbolAtPosition(result, pos) orelse {
        // シンボルテーブルにない場合、名前で全シンボルを検索
        for (result.symbols) |*s| {
            if (std.mem.eql(u8, s.name, receiver_name)) {
                return s.type_name;
            }
        }
        return null;
    };
    return sym.type_name;
}

/// 型ベースのドット補完。SObject フィールド + 標準ライブラリメソッド。
fn getDotCompletions(type_name: []const u8, result: *const binder_mod.BindResult, allocator: std.mem.Allocator, custom_fields: ?*const sobject_schema.CustomFieldRegistry) ![]lsp_types.CompletionItem {
    var items: std.ArrayList(lsp_types.CompletionItem) = .empty;

    // SObject 標準フィールド
    if (sobject_schema.getFields(type_name)) |fields| {
        for (fields) |f| {
            try items.append(allocator, .{
                .label = f.name,
                .kind = .field,
                .detail = f.type_name,
            });
        }
    }

    // カスタムフィールド (__c / __mdt 等)
    if (custom_fields) |cf| {
        if (cf.getFields(type_name)) |fields| {
            for (fields) |f| {
                try items.append(allocator, .{
                    .label = f.name,
                    .kind = .field,
                    .detail = f.type_name,
                });
            }
        }
    }

    // Apex 標準ライブラリメソッド
    if (apex_stdlib.getMembers(type_name)) |members| {
        for (members) |m| {
            try items.append(allocator, .{
                .label = m.name,
                .kind = if (m.kind == .method) .method else .field,
                .detail = m.detail,
            });
        }
    }

    // binder 内の同じクラスのメンバー（ユーザー定義クラス）
    for (result.symbols) |sym| {
        if (sym.parent) |parent_id| {
            if (parent_id < result.symbols.len) {
                const parent = &result.symbols[parent_id];
                if (parent.kind == .class and std.mem.eql(u8, parent.name, type_name)) {
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

    return items.toOwnedSlice(allocator);
}

/// 通常補完: スコープ内シンボル + キーワード。
fn getDefaultCompletions(result: *const binder_mod.BindResult, allocator: std.mem.Allocator) ![]lsp_types.CompletionItem {
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

fn completeAt(source: []const u8, offset: u32) !TestComplCtx {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const alloc = arena.allocator();
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);
    const items = try getCompletions(&br, source, offset, alloc, null);
    return .{ .items = items, .arena = arena };
}

fn hasLabel(items: []const lsp_types.CompletionItem, label: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return true;
    }
    return false;
}

fn hasLabelWithKind(items: []const lsp_types.CompletionItem, label: []const u8, kind: lsp_types.CompletionItemKind) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label) and item.kind != null and item.kind.? == kind) return true;
    }
    return false;
}

// -- 既存テスト --

test "local variables in completions" {
    const source = "public class Foo { public void run() { Integer myVar = 1; } }";
    var ctx = try completeAt(source, 50);
    defer ctx.deinit();

    try std.testing.expect(hasLabel(ctx.items, "myVar"));
}

test "keywords in completions" {
    const source = "public class Foo {}";
    var ctx = try completeAt(source, 10);
    defer ctx.deinit();

    try std.testing.expect(hasLabel(ctx.items, "public"));
    try std.testing.expect(hasLabel(ctx.items, "class"));
    try std.testing.expect(hasLabel(ctx.items, "String"));
}

test "method parameters visible" {
    const source = "public class Foo { public void run(String name) {} }";
    var ctx = try completeAt(source, 45);
    defer ctx.deinit();

    try std.testing.expect(hasLabel(ctx.items, "name"));
}

// -- ドット補完テスト --

test "dot completion: Account fields after acc." {
    // "acc." のドットの直後が offset
    const source = "public class Foo { public void run() { Account acc; acc. } }";
    const dot_pos = std.mem.indexOf(u8, source, "acc. ").? + 4; // "acc." の直後
    var ctx = try completeAt(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(hasLabelWithKind(ctx.items, "Id", .field));
    try std.testing.expect(hasLabelWithKind(ctx.items, "Name", .field));
    try std.testing.expect(hasLabelWithKind(ctx.items, "Phone", .field));
    // キーワードは含まれない
    try std.testing.expect(!hasLabel(ctx.items, "public"));
}

test "dot completion: String methods after str." {
    const source = "public class Foo { public void run() { String str; str. } }";
    const dot_pos = std.mem.indexOf(u8, source, "str. ").? + 4;
    var ctx = try completeAt(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(hasLabelWithKind(ctx.items, "length", .method));
    try std.testing.expect(hasLabelWithKind(ctx.items, "toLowerCase", .method));
    try std.testing.expect(hasLabelWithKind(ctx.items, "contains", .method));
}

test "dot completion: System.debug static access" {
    const source = "public class Foo { public void run() { System. } }";
    const dot_pos = std.mem.indexOf(u8, source, "System. ").? + 7;
    var ctx = try completeAt(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(hasLabelWithKind(ctx.items, "debug", .method));
    try std.testing.expect(hasLabelWithKind(ctx.items, "assertEquals", .method));
}

test "dot completion: List methods after list." {
    const source = "public class Foo { public void run() { List items; items. } }";
    const dot_pos = std.mem.indexOf(u8, source, "items. ").? + 6;
    var ctx = try completeAt(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(hasLabelWithKind(ctx.items, "add", .method));
    try std.testing.expect(hasLabelWithKind(ctx.items, "size", .method));
    try std.testing.expect(hasLabelWithKind(ctx.items, "isEmpty", .method));
}

test "dot completion: Contact fields" {
    const source = "public class Foo { public void run() { Contact c; c. } }";
    const dot_pos = std.mem.indexOf(u8, source, "c. ").? + 2;
    var ctx = try completeAt(source, @intCast(dot_pos));
    defer ctx.deinit();

    try std.testing.expect(hasLabelWithKind(ctx.items, "FirstName", .field));
    try std.testing.expect(hasLabelWithKind(ctx.items, "LastName", .field));
    try std.testing.expect(hasLabelWithKind(ctx.items, "Email", .field));
}

test "no dot: returns keywords and symbols, not SObject fields" {
    const source = "public class Foo { public void run() { Account acc; } }";
    var ctx = try completeAt(source, 50);
    defer ctx.deinit();

    try std.testing.expect(hasLabel(ctx.items, "acc"));
    try std.testing.expect(hasLabel(ctx.items, "public"));
    // SObject フィールドは含まれない
    try std.testing.expect(!hasLabel(ctx.items, "Phone"));
}
