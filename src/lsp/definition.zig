//! definition — カーソル位置のシンボルの定義位置を返す。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");
const DocumentStore = @import("document_store.zig").DocumentStore;
const parser_types = @import("../apex_parser/types.zig");

/// 同一ファイル内でシンボルの定義位置を返す。
pub fn get_definition(
    result: *const binder_mod.BindResult,
    source: []const u8,
    uri: []const u8,
    offset: u32,
) ?lsp_types.Location {
    const sym = binder_mod.symbol_at_position(result, offset) orelse return null;
    const pos = position_mod.offset_to_position(source, sym.loc.offset);
    return .{
        .uri = uri,
        .range = .{
            .start = pos,
            .end = .{ .line = pos.line, .character = pos.character + @as(
                u32,
                @intCast(sym.name.len),
            ) },
        },
    };
}

/// クロスファイル対応版。同一ファイルで見つからない場合、ワークスペース内の他ファイルを検索する。
pub fn get_definition_cross_file(
    result: *const binder_mod.BindResult,
    tokens: []const parser_types.Token,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    store: *DocumentStore,
) ?lsp_types.Location {
    // 1. 同一ファイル内で検索
    if (get_definition(result, source, uri, offset)) |loc| return loc;

    // 2. `this.member` の member 側を現在クラスのメンバーへ解決
    if (position_mod.this_member_at_offset(tokens, offset)) |member| {
        if (resolve_this_member(result, offset, member.member_name)) |sym| {
            return location_for_symbol(sym, source, uri);
        }
    }

    // 3. `ClassName.member` の member 側をワークスペース内のクラスメンバーへ解決
    if (position_mod.qualified_member_at_offset(tokens, offset)) |member| {
        if (store.resolve_member_across_files(
            member.receiver_name,
            member.member_name,
            uri,
        )) |match| {
            return location_for_symbol(&match.symbol, match.source, match.uri);
        }
    }

    // 4. カーソル位置の identifier を取得
    const name = position_mod.identifier_at_offset(tokens, offset) orelse return null;

    // 5. ワークスペース内の他ファイルで検索
    const match = store.resolve_symbol_across_files(name, uri) orelse return null;
    return location_for_symbol(&match.symbol, match.source, match.uri);
}

fn resolve_this_member(
    result: *const binder_mod.BindResult,
    offset: u32,
    member_name: []const u8,
) ?*const binder_mod.Symbol {
    const owner_id = current_class_symbol_id(result, offset) orelse return null;
    for (result.symbols) |*sym| {
        if (sym.parent == null or sym.parent.? != owner_id) continue;
        if (!is_class_member(sym.kind)) continue;
        if (std.mem.eql(u8, sym.name, member_name)) return sym;
    }
    return null;
}

fn current_class_symbol_id(
    result: *const binder_mod.BindResult,
    offset: u32,
) ?binder_mod.SymbolId {
    var owner_id: ?binder_mod.SymbolId = null;
    var owner_offset: u32 = 0;
    for (result.symbols) |sym| {
        if (sym.kind != .class and sym.kind != .interface) continue;
        if (sym.loc.offset > offset) continue;
        if (owner_id == null or sym.loc.offset >= owner_offset) {
            owner_id = sym.id;
            owner_offset = sym.loc.offset;
        }
    }
    return owner_id;
}

fn is_class_member(kind: binder_mod.SymbolKind) bool {
    return switch (kind) {
        .method, .field, .constructor, .enum_value, .class, .interface, .enum_type => true,
        else => false,
    };
}

fn location_for_symbol(
    sym: *const binder_mod.Symbol,
    source: []const u8,
    uri: []const u8,
) lsp_types.Location {
    const pos = position_mod.offset_to_position(source, sym.loc.offset);
    return .{
        .uri = uri,
        .range = .{
            .start = pos,
            .end = .{ .line = pos.line, .character = pos.character + @as(
                u32,
                @intCast(sym.name.len),
            ) },
        },
    };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

fn def_at(source: []const u8, offset: u32) !?lsp_types.Location {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);
    return get_definition(&br, source, "file:///test.cls", offset);
}

test "variable use jumps to declaration" {
    const source = "public class Foo { public void run() { Integer x = 1; Integer y = x; } }";
    // 'x' の使用位置（'= x;' の x）を探す
    const use_offset = std.mem.lastIndexOf(u8, source, "x;").?;
    const loc = try def_at(source, @intCast(use_offset));
    try std.testing.expect(loc != null);
}

test "unknown symbol returns null" {
    const source = "public class Foo {}";
    const loc = try def_at(source, 6); // space
    try std.testing.expect(loc == null);
}

// -- クロスファイルテスト --

test "cross-file: jump to class in another file" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    // Helper.cls: class Helper の定義
    try store.open("file:///Helper.cls", 1, "public class Helper { public void doWork() {} }");
    // Main.cls: Helper を参照
    const main_source = "public class Main { Helper h; }";
    try store.open("file:///Main.cls", 1, main_source);

    // 両方パース+バインド
    _ = try store.ensure_bound("file:///Helper.cls");
    const main_cached = try store.ensure_parsed("file:///Main.cls") orelse unreachable;
    const main_br = try store.ensure_bound("file:///Main.cls") orelse unreachable;

    // 'Helper' の位置を探す（"Main { Helper" の Helper）
    const helper_offset: u32 = @intCast(std.mem.indexOf(u8, main_source, "Helper h").?);

    const loc = get_definition_cross_file(
        main_br,
        main_cached.tokens,
        main_source,
        "file:///Main.cls",
        helper_offset,
        &store,
    );
    try std.testing.expect(loc != null);
    try std.testing.expectEqualStrings("file:///Helper.cls", loc.?.uri);
}

test "cross-file: jump to class member in another file" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open(
        "file:///Helper.cls",
        1,
        "public class Helper { public String doWork() { return null; } }",
    );
    const main_source = "public class Main { void run() { Helper.doWork(); } }";
    try store.open("file:///Main.cls", 1, main_source);

    const main_cached = try store.ensure_parsed("file:///Main.cls") orelse unreachable;
    const main_br = try store.ensure_bound("file:///Main.cls") orelse unreachable;
    const offset: u32 = @intCast(std.mem.indexOf(u8, main_source, "doWork").?);

    const loc = get_definition_cross_file(
        main_br,
        main_cached.tokens,
        main_source,
        "file:///Main.cls",
        offset,
        &store,
    );
    try std.testing.expect(loc != null);
    try std.testing.expectEqualStrings("file:///Helper.cls", loc.?.uri);
    try std.testing.expectEqual(@as(u32, 36), loc.?.range.start.character);
}

test "same-file: this field jumps to class field" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const source =
        \\public class Foo {
        \\    private Integer recordCount;
        \\    public void run() { this.recordCount = 1; }
        \\}
    ;
    try store.open("file:///Foo.cls", 1, source);
    const cached = try store.ensure_parsed("file:///Foo.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Foo.cls") orelse unreachable;
    const offset: u32 = @intCast(std.mem.lastIndexOf(u8, source, "recordCount").?);

    const loc = get_definition_cross_file(
        br,
        cached.tokens,
        source,
        "file:///Foo.cls",
        offset,
        &store,
    );
    try std.testing.expect(loc != null);
    try std.testing.expectEqualStrings("file:///Foo.cls", loc.?.uri);
    try std.testing.expectEqual(@as(u32, 20), loc.?.range.start.character);
}

test "same-file: this method jumps to class method" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const source =
        \\public class Foo {
        \\    public void run() { this.compute(); }
        \\    private Integer compute() { return 1; }
        \\}
    ;
    try store.open("file:///Foo.cls", 1, source);
    const cached = try store.ensure_parsed("file:///Foo.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Foo.cls") orelse unreachable;
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "compute").?);

    const loc = get_definition_cross_file(
        br,
        cached.tokens,
        source,
        "file:///Foo.cls",
        offset,
        &store,
    );
    try std.testing.expect(loc != null);
    try std.testing.expectEqualStrings("file:///Foo.cls", loc.?.uri);
    try std.testing.expectEqual(@as(u32, 20), loc.?.range.start.character);
}

test "cross-file: same-file symbol takes priority" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const source = "public class Foo { public void run() { Integer x = 1; Integer y = x; } }";
    try store.open("file:///Foo.cls", 1, source);
    const cached = try store.ensure_parsed("file:///Foo.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Foo.cls") orelse unreachable;

    // 'x' の使用位置
    const use_offset: u32 = @intCast(std.mem.lastIndexOf(u8, source, "x;").?);
    const loc = get_definition_cross_file(
        br,
        cached.tokens,
        source,
        "file:///Foo.cls",
        use_offset,
        &store,
    );
    try std.testing.expect(loc != null);
    try std.testing.expectEqualStrings("file:///Foo.cls", loc.?.uri); // 同じファイル
}

test "cross-file: returns null when symbol not found anywhere" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const source = "public class Main { Unknown x; }";
    try store.open("file:///Main.cls", 1, source);
    const cached = try store.ensure_parsed("file:///Main.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Main.cls") orelse unreachable;

    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "Unknown").?);
    const loc = get_definition_cross_file(
        br,
        cached.tokens,
        source,
        "file:///Main.cls",
        offset,
        &store,
    );
    try std.testing.expect(loc == null);
}
